defmodule SymphonyElixir.DeliveryRunner do
  @moduledoc """
  Deterministic delivery phase for Symphony v2 parent issues.

  Delivery integrates accepted child work into one parent branch, publishes one
  draft PR/Preview, optionally runs preview seeding, and writes Daniel's final
  review handoff to Linear.
  """

  require Logger

  alias SymphonyElixir.{Config, CoordinatorPlan, Tracker}
  alias SymphonyElixir.Linear.Issue

  @ignored_child_states ["canceled", "cancelled", "duplicate"]

  @spec run(Issue.t()) :: :ok
  def run(%Issue{} = parent) do
    Logger.info("DeliveryRunner evaluating #{parent.identifier || parent.id}")

    with {:ok, plan} <- CoordinatorPlan.from_issue(parent),
         {:ok, child_specs} <- child_specs(parent),
         {:ok, publish} <- publish_parent(parent, child_specs),
         :ok <- maybe_seed_preview(plan.delivery, publish),
         :ok <- mark_preview_ready(parent, plan.delivery, publish) do
      :ok
    else
      {:error, {:child_rework, child, reason}} ->
        rework_child(parent, child, reason)

      {:error, reason} ->
        block_parent(parent, reason)
    end
  end

  @doc false
  def child_specs_for_test(%Issue{} = parent), do: child_specs(parent)

  defp child_specs(%Issue{children: children}) when is_list(children) and children != [] do
    active_children = Enum.reject(children, &ignored_child?/1)

    if active_children == [] do
      {:error, "Parent has no active child issues to integrate."}
    else
      build_child_specs(active_children)
    end
  end

  defp child_specs(_parent), do: {:error, "Parent has no child issues to integrate."}

  defp build_child_specs(children) do
    specs =
      Enum.map(children, fn child ->
        %{
          id: child_id(child),
          identifier: child_identifier(child),
          branch: child_branch(child)
        }
      end)

    if Enum.any?(specs, &is_nil(&1.identifier)) do
      {:error, "At least one child issue has no identifier; cannot locate worktree for delivery."}
    else
      {:ok, specs}
    end
  end

  defp publish_parent(%Issue{} = parent, child_specs) do
    repo_root = System.get_env("SYMPHONY_REPO_ROOT") || File.cwd!()
    script = Path.join(repo_root, "scripts/symphony-deliver.sh")

    if File.exists?(script) do
      parent_identifier = parent.identifier || parent.id

      child_args =
        Enum.map(child_specs, fn spec ->
          "#{spec.identifier}:#{spec.branch || ""}"
        end)

      env = [
        {"SYMPHONY_REPO_ROOT", repo_root},
        {"SYMPHONY_WORKTREE_ROOT", Path.expand(Config.settings!().workspace.root)}
      ]

      {output, exit_code} =
        System.cmd("bash", [script, parent_identifier] ++ child_args,
          cd: repo_root,
          env: env,
          stderr_to_stdout: true
        )

      publish = parse_publish_output(output, exit_code)

      case {exit_code, publish.status} do
        {_, "ready-for-review-link"} ->
          {:ok, publish}

        {20, "blocked-merge-conflict"} ->
          child_identifier = capture_line(output, ~r/^Child:\s*(.+)$/m)
          child = Enum.find(child_specs, &(&1.identifier == child_identifier))
          {:error, {:child_rework, child, "Child branch merge conflict.\n\n#{output}"}}

        _ ->
          {:error, "Delivery publish failed or did not produce a Preview URL.\n\n#{output}"}
      end
    else
      {:error, "Delivery script not found at #{script}"}
    end
  end

  defp maybe_seed_preview(delivery, publish) do
    cond do
      delivery.persona_needed != true ->
        :ok

      !is_binary(publish.preview_url) or publish.preview_url == "" ->
        {:error, "Preview seeding was required, but delivery did not produce a Preview URL."}

      is_binary(System.get_env("SYMPHONY_PREVIEW_SEED_COMMAND")) ->
        run_custom_seed_command(publish)

      is_binary(System.get_env("WOLF_API_KEY")) ->
        case preview_api_url() do
          {:ok, api_url} ->
            run_default_seed_command(api_url)

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error,
         "Preview seeding is required for this parent, but WOLF_API_KEY or SYMPHONY_PREVIEW_SEED_COMMAND is missing."}
    end
  end

  defp run_custom_seed_command(publish) do
    repo_root = System.get_env("SYMPHONY_REPO_ROOT") || File.cwd!()
    command = System.get_env("SYMPHONY_PREVIEW_SEED_COMMAND")

    env = [
      {"SYMPHONY_PREVIEW_URL", publish.preview_url}
    ]
    |> maybe_add_preview_api_env()

    case System.cmd("bash", ["-lc", command], cd: repo_root, env: env, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, "Custom Preview seed command failed with exit #{code}.\n\n#{output}"}
    end
  end

  defp run_default_seed_command(api_url) do
    repo_root = System.get_env("SYMPHONY_REPO_ROOT") || File.cwd!()

    env = [
      {"WOLF_BASE_URL", api_url},
      {"WOLF_API_KEY", System.get_env("WOLF_API_KEY")}
    ]

    case System.cmd("npm", ["run", "seed:preview"], cd: repo_root, env: env, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, "Preview seed failed with exit #{code}.\n\n#{output}"}
    end
  end

  defp maybe_add_preview_api_env(env) do
    case preview_api_url() do
      {:ok, api_url} -> [{"WOLF_BASE_URL", api_url} | env]
      {:error, _reason} -> env
    end
  end

  defp preview_api_url do
    cond do
      preview_api_url = non_empty_env("SYMPHONY_PREVIEW_API_URL") ->
        {:ok, preview_api_url}

      preview_ref = non_empty_env("SYMPHONY_PREVIEW_SUPABASE_REF") ->
        {:ok, "https://#{preview_ref}.supabase.co/functions/v1/api"}

      true ->
        {:error,
         "Preview seeding requires SYMPHONY_PREVIEW_API_URL or SYMPHONY_PREVIEW_SUPABASE_REF. Refusing to seed via the Vercel Preview app URL."}
    end
  end

  if Mix.env() == :test do
    @doc false
    def preview_api_url_for_test, do: preview_api_url()
  end

  defp non_empty_env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp mark_preview_ready(%Issue{} = parent, delivery, publish) do
    comment = """
    ## Symphony Delivery Summary

    Parent issue: #{parent.identifier || parent.id} / #{parent.title}
    Child issues integrated: #{child_summary(parent.children)}
    PR: #{publish.pr_url}
    Preview: #{publish.preview_url}
    Persona: #{delivery.persona}

    Steps to test:
    #{Enum.map_join(delivery.steps_to_test, "\n", &"- #{&1}")}

    Validation: Delivery branch integrated child work and published one draft PR/Preview.
    Decision needed: approve
    """

    with :ok <- Tracker.add_labels(parent.id, ["Preview Ready"]),
         :ok <- Tracker.create_comment(parent.id, comment),
         :ok <- Tracker.update_issue_state(parent.id, "In Review") do
      :ok
    else
      {:error, reason} -> {:error, "Could not mark parent Preview Ready: #{inspect(reason)}"}
    end
  end

  defp block_parent(%Issue{} = parent, reason) do
    comment = """
    ## Symphony Coordinator Required

    Parent issue: #{parent.identifier || parent.id} / #{parent.title}
    Result: Delivery stopped safely before Daniel review.
    Reason: #{reason}
    Decision needed: blocked
    """

    Tracker.add_labels(parent.id, ["Coordinator Required"])
    Tracker.create_comment(parent.id, comment)
    Tracker.update_issue_state(parent.id, "In Review")
    :ok
  end

  defp rework_child(%Issue{} = parent, %{id: child_id, identifier: child_identifier}, reason)
       when is_binary(child_id) do
    comment = """
    ## Coordinator Rework Required

    Child issue: #{child_identifier || child_id}
    Parent issue: #{parent.identifier || parent.id}
    Result: Delivery integration failed before parent Preview.
    Reason: #{reason}
    Expected action: resolve the integration conflict or blocker, then move this child back to `In Review` for Coordinator delivery.
    Decision needed: coordinator
    """

    Tracker.create_comment(child_id, comment)
    Tracker.update_issue_state(child_id, "Todo")
    :ok
  end

  defp rework_child(%Issue{} = parent, _child, reason) do
    block_parent(parent, "A child requires rework, but the Coordinator could not resolve its Linear issue id.\n\n#{reason}")
  end

  defp parse_publish_output(output, exit_code) do
    %{
      exit_code: exit_code,
      output: output,
      status: capture_line(output, ~r/^Status:\s*(.+)$/m),
      pr_url: capture_url_line(output, "PR"),
      preview_url: capture_url_line(output, "Preview")
    }
  end

  defp capture_line(output, regex) do
    case Regex.run(regex, output) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp capture_url_line(output, label) do
    case Regex.run(~r/^#{Regex.escape(label)}:\s*(https?:\/\/\S+)$/m, output) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp child_summary(children) when is_list(children) do
    children
    |> Enum.reject(&ignored_child?/1)
    |> Enum.map_join(", ", fn child -> child_identifier(child) || "unknown-child" end)
  end

  defp child_summary(_children), do: "none"

  defp child_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp child_identifier(%{"identifier" => identifier}) when is_binary(identifier), do: identifier
  defp child_identifier(%{id: id}) when is_binary(id), do: id
  defp child_identifier(%{"id" => id}) when is_binary(id), do: id
  defp child_identifier(_child), do: nil

  defp child_id(%{id: id}) when is_binary(id), do: id
  defp child_id(%{"id" => id}) when is_binary(id), do: id
  defp child_id(_child), do: nil

  defp child_branch(%{branch_name: branch}) when is_binary(branch), do: usable_child_branch(branch)
  defp child_branch(%{"branch_name" => branch}) when is_binary(branch), do: usable_child_branch(branch)
  defp child_branch(%{"branchName" => branch}) when is_binary(branch), do: usable_child_branch(branch)
  defp child_branch(_child), do: nil

  defp usable_child_branch("codex/" <> _ = branch), do: branch
  defp usable_child_branch(_branch), do: nil

  defp ignored_child?(child) do
    child
    |> child_state()
    |> normalize_state()
    |> then(&(&1 in @ignored_child_states))
  end

  defp child_state(%{state: %{name: name}}) when is_binary(name), do: name
  defp child_state(%{"state" => %{"name" => name}}) when is_binary(name), do: name
  defp child_state(%{state: state}) when is_binary(state), do: state
  defp child_state(%{"state" => state}) when is_binary(state), do: state
  defp child_state(%{status: status}) when is_binary(status), do: status
  defp child_state(%{"status" => status}) when is_binary(status), do: status
  defp child_state(_child), do: nil

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: nil
end
