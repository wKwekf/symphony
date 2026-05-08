defmodule SymphonyElixir.CoordinatorRunner do
  @moduledoc """
  Symphony v2 coordinator runner.

  The coordinator owns parent `Agent Epic` issues: it shapes requirements,
  creates worker child issues, waits for worker handoffs, and invokes delivery
  once all children are ready for integration.
  """

  require Logger

  alias SymphonyElixir.{CoordinatorPlan, DeliveryRunner, Tracker}
  alias SymphonyElixir.Linear.Issue

  @required_labels [
    "Agent Epic",
    "Agent Worker",
    "Agent Ready",
    "Coordinator Required",
    "Preview Ready",
    "Needs Shaping"
  ]

  @hold_labels ["needs shaping", "coordinator required", "human review required"]

  @spec required_labels() :: [String.t()]
  def required_labels, do: @required_labels

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok
  def run(%Issue{} = issue, _recipient \\ nil, _opts \\ []) do
    Logger.info("CoordinatorRunner evaluating #{issue.identifier || issue.id}")

    with {:ok, _labels} <- Tracker.ensure_labels(@required_labels) do
      cond do
        hold_label?(issue) ->
          Logger.info("CoordinatorRunner skipping held parent #{issue.identifier || issue.id}")
          :ok

        preview_ready?(issue) ->
          Logger.info("CoordinatorRunner skipping preview-ready parent #{issue.identifier || issue.id}")
          :ok

        no_children?(issue) and normalize(issue.state) == "todo" ->
          shape_or_create_children(issue)

        no_children?(issue) ->
          Logger.info("CoordinatorRunner waiting for Linear child visibility on #{issue.identifier || issue.id}")
          :ok

        only_ignored_children?(issue) ->
          Logger.info("CoordinatorRunner regenerating children for #{issue.identifier || issue.id}; existing children are canceled/ignored")
          shape_or_create_children(issue)

        blocked_children?(issue) ->
          block_parent(issue, "One or more child issues are blocked or marked Coordinator Required: #{blocked_child_summary(issue)}")

        all_children_ready?(issue) ->
          DeliveryRunner.run(issue)

        true ->
          Logger.info("CoordinatorRunner waiting for child work on #{issue.identifier || issue.id}")
          ensure_parent_in_progress(issue)
      end
    else
      {:error, reason} ->
        block_parent(issue, "Coordinator could not bootstrap Linear labels: #{inspect(reason)}")
    end
  end

  defp shape_or_create_children(%Issue{} = issue) do
    case CoordinatorPlan.from_issue(issue) do
      {:ok, %{mode: "clarify", questions: questions}} ->
        clarify(issue, questions)

      {:ok, %{children: children, delivery: delivery}} ->
        create_children(issue, children, delivery)

      {:error, reason} ->
        block_parent(issue, "Coordinator could not parse the parent plan: #{inspect(reason)}")
    end
  end

  defp create_children(%Issue{} = issue, children, delivery) when is_list(children) do
    ensure_parent_in_progress(issue)

    results =
      Enum.map(children, fn child ->
        attrs = %{
          parent_id: issue.id,
          title: child.title,
          description: CoordinatorPlan.child_description(issue, child, delivery),
          priority: issue.priority || 3,
          state: "Todo",
          labels: child.labels
        }

        {child, Tracker.create_issue(attrs)}
      end)

    errors =
      Enum.flat_map(results, fn
        {_child, {:ok, _issue}} -> []
        {child, {:error, reason}} -> [{child, reason}]
      end)

    if errors == [] do
      created =
        Enum.flat_map(results, fn
          {child, {:ok, %Issue{} = created_issue}} ->
            ["- #{created_issue.identifier || created_issue.id}: #{child.title}"]

          {child, {:ok, created_issue}} ->
            ["- #{inspect(created_issue)}: #{child.title}"]

          _ ->
            []
        end)

      comment = """
      ## Symphony Coordinator Plan

      Parent: #{issue.identifier || issue.id} / #{issue.title}
      Mode: child-worker execution

      Created child issues:
      #{Enum.join(created, "\n")}

      Delivery target: #{delivery.review_surface}
      Persona: #{delivery.persona}

      Coordinator will wait until all child issues are in `In Review` or done, then integrate and publish one parent Preview.
      Decision needed: coordinator
      """

      create_comment(issue, comment)
      :ok
    else
      if Enum.all?(errors, &transient_child_create_error?/1) do
        retry_child_creation_later(issue, errors)
      else
        block_parent(issue, "Coordinator could not create all child issues:\n#{format_child_create_errors(errors)}")
      end
    end
  end

  defp retry_child_creation_later(%Issue{} = issue, errors) do
    comment = """
    ## Symphony Coordinator Retry

    Parent: #{issue.identifier || issue.id} / #{issue.title}
    Result: Coordinator hit a transient Linear API error while creating child issues.
    Reason:
    #{format_child_create_errors(errors)}

    Action: leaving the parent active so the next Symphony poll can retry automatically.
    Decision needed: coordinator
    """

    create_comment(issue, comment)
    ensure_parent_in_progress(issue)
    :ok
  end

  defp format_child_create_errors(errors) do
    Enum.map_join(errors, "\n", fn {child, reason} ->
      "#{child.title}: #{inspect(reason)}"
    end)
  end

  defp transient_child_create_error?({_child, reason}), do: transient_error?(reason)

  defp transient_error?({:linear_api_request, %Req.TransportError{reason: :timeout}}), do: true
  defp transient_error?({:linear_api_request, %{reason: :timeout}}), do: true
  defp transient_error?({:linear_api_request, :timeout}), do: true
  defp transient_error?(_reason), do: false

  defp clarify(%Issue{} = issue, questions) do
    comment = """
    ## Needs Shaping

    The Coordinator needs these answers before creating worker child issues:

    #{Enum.map_join(questions, "\n", &"- #{&1}")}

    Once answered, remove `Needs Shaping` and move the parent back to `Todo`.
    Decision needed: needs product decision
    """

    create_comment(issue, comment)
    add_labels(issue, ["Needs Shaping"])
    update_state(issue, "In Review")
    :ok
  end

  defp block_parent(%Issue{} = issue, reason) do
    comment = """
    ## Symphony Coordinator Required

    Parent: #{issue.identifier || issue.id} / #{issue.title}
    Result: Coordinator stopped safely.
    Reason: #{reason}
    Next step: inspect the blocker, then move the parent back to `Todo` only when another Coordinator run is intentional.
    Decision needed: blocked
    """

    create_comment(issue, comment)
    add_labels(issue, ["Coordinator Required"])
    update_state(issue, "In Review")
    :ok
  end

  defp ensure_parent_in_progress(%Issue{state: state} = issue) do
    if normalize(state) == "todo" do
      update_state(issue, "In Progress")
    else
      :ok
    end
  end

  defp all_children_ready?(%Issue{children: children}) when is_list(children) and children != [] do
    case fetch_child_issues(children) do
      {:ok, child_issues} when length(child_issues) == length(children) ->
        child_issues
        |> active_child_issues()
        |> case do
          [] -> false
          active_children -> Enum.all?(active_children, &child_ready_for_delivery?/1)
        end

      _ ->
        false
    end
  end

  defp all_children_ready?(_issue), do: false

  defp blocked_children?(%Issue{children: children}) when is_list(children) and children != [] do
    case fetch_child_issues(children) do
      {:ok, child_issues} ->
        child_issues
        |> active_child_issues()
        |> Enum.any?(&child_blocked?/1)

      _ -> false
    end
  end

  defp blocked_children?(_issue), do: false

  defp child_ready_for_delivery?(%Issue{state: state} = child) when is_binary(state) do
    normalize(state) in ["in review", "done", "closed"] and !child_blocked?(child)
  end

  defp child_ready_for_delivery?(_child), do: false

  defp child_blocked?(%Issue{} = child) do
    hold_label?(child)
  end

  defp child_blocked?(_child), do: false

  defp fetch_child_issues(children) when is_list(children) do
    ids = Enum.flat_map(children, &child_id/1)

    if ids == [] do
      {:ok, []}
    else
      Tracker.fetch_issue_states_by_ids(ids)
    end
  end

  defp child_id(%{id: id}) when is_binary(id), do: [id]
  defp child_id(%{"id" => id}) when is_binary(id), do: [id]
  defp child_id(_child), do: []

  defp blocked_child_summary(%Issue{children: children}) when is_list(children) do
    case fetch_child_issues(children) do
      {:ok, child_issues} ->
        child_issues
        |> active_child_issues()
        |> Enum.filter(&child_blocked?/1)
        |> Enum.map_join(", ", &(&1.identifier || &1.id || "unknown-child"))

      _ ->
        "unknown child"
    end
  end

  defp blocked_child_summary(_issue), do: "unknown child"

  defp active_child_issues(child_issues) when is_list(child_issues) do
    Enum.reject(child_issues, &ignored_child?/1)
  end

  defp only_ignored_children?(%Issue{children: children}) when is_list(children) and children != [] do
    case fetch_child_issues(children) do
      {:ok, child_issues} when child_issues != [] ->
        active_child_issues(child_issues) == []

      _ ->
        false
    end
  end

  defp only_ignored_children?(_issue), do: false

  defp ignored_child?(%Issue{state: state}) when is_binary(state) do
    normalize(state) in ["canceled", "cancelled", "duplicate"]
  end

  defp ignored_child?(_child), do: false

  defp no_children?(%Issue{children: children}) when is_list(children), do: children == []
  defp no_children?(_issue), do: true

  defp preview_ready?(%Issue{} = issue), do: label?(issue, "preview ready")
  defp hold_label?(%Issue{} = issue), do: Enum.any?(@hold_labels, &label?(issue, &1))

  defp label?(%Issue{labels: labels}, wanted) when is_list(labels) do
    wanted = normalize(wanted)
    Enum.any?(labels, &(normalize(&1) == wanted))
  end

  defp label?(_issue, _wanted), do: false

  defp create_comment(%Issue{id: issue_id}, comment) when is_binary(issue_id) do
    case Tracker.create_comment(issue_id, comment) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Coordinator comment failed for #{issue_id}: #{inspect(reason)}")
    end
  end

  defp add_labels(%Issue{id: issue_id}, labels) when is_binary(issue_id) do
    case Tracker.add_labels(issue_id, labels) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Coordinator label update failed for #{issue_id}: #{inspect(reason)}")
    end
  end

  defp update_state(%Issue{id: issue_id}, state) when is_binary(issue_id) do
    case Tracker.update_issue_state(issue_id, state) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Coordinator state update failed for #{issue_id}: #{inspect(reason)}")
    end
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end
end
