defmodule SymphonyElixir.ReleaseRunner do
  @moduledoc """
  Deterministic production release phase for Symphony v2 parent issues.

  A parent issue becomes release-eligible only after Daniel marks the reviewed
  Preview with `Production Approved`. The runner then merges the parent delivery
  PR, waits for Production deployment success, and closes the Linear issue.
  """

  require Logger

  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Linear.Issue

  @required_labels [
    "Production Approved",
    "Production Deployed",
    "Coordinator Required"
  ]

  @blocking_hold_labels ["needs shaping", "coordinator required"]
  @risk_labels ["auth/rls", "migration", "production data", "external email", "high risk"]

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok
  def run(%Issue{} = issue, _recipient \\ nil, _opts \\ []) do
    Logger.info("ReleaseRunner evaluating #{issue.identifier || issue.id}")

    with {:ok, _labels} <- Tracker.ensure_labels(@required_labels),
         :ok <- validate_release_candidate(issue),
         {:ok, release} <- release_parent(issue),
         :ok <- mark_production_deployed(issue, release) do
      :ok
    else
      {:blocked, reason} ->
        block_parent(issue, reason)

      {:error, reason} ->
        block_parent(issue, reason)
    end
  end

  @doc false
  def validate_release_candidate_for_test(%Issue{} = issue), do: validate_release_candidate(issue)

  @doc false
  def parse_release_output_for_test(output, exit_code), do: parse_release_output(output, exit_code)

  defp validate_release_candidate(%Issue{} = issue) do
    labels = label_set(issue)

    cond do
      !MapSet.member?(labels, "agent epic") ->
        {:blocked, "Production release requires a parent `Agent Epic` issue."}

      !MapSet.member?(labels, "preview ready") ->
        {:blocked, "Production release requires `Preview Ready`."}

      !MapSet.member?(labels, "production approved") ->
        {:blocked, "Production release requires Daniel's `Production Approved` label."}

      normalize_label(issue.state || "") != "in review" ->
        {:blocked, "Production release requires the parent issue to be in `In Review`."}

      !MapSet.disjoint?(labels, MapSet.new(@blocking_hold_labels)) ->
        {:blocked, "Production release is blocked by `Needs Shaping` or `Coordinator Required`."}

      !MapSet.disjoint?(labels, MapSet.new(@risk_labels)) ->
        {:blocked, "Production release is high-risk and must stay manual in v1."}

      MapSet.member?(labels, "production deployed") ->
        {:blocked, "Production is already marked as deployed."}

      !is_binary(issue.identifier) or String.trim(issue.identifier) == "" ->
        {:blocked, "Production release requires a Linear issue identifier such as HB-123."}

      !is_binary(issue.id) or String.trim(issue.id) == "" ->
        {:blocked, "Production release requires a Linear issue id for closeout updates."}

      true ->
        :ok
    end
  end

  defp release_parent(%Issue{} = issue) do
    repo_root = System.get_env("SYMPHONY_REPO_ROOT") || File.cwd!()

    {output, exit_code} =
      case System.get_env("SYMPHONY_RELEASE_COMMAND") do
        command when is_binary(command) and command != "" ->
          System.cmd("bash", ["-lc", command],
            cd: repo_root,
            env: [{"SYMPHONY_RELEASE_ISSUE", issue.identifier || issue.id || ""}],
            stderr_to_stdout: true
          )

        _ ->
          script = Path.join(repo_root, "scripts/symphony-release.sh")

          if File.exists?(script) do
            System.cmd("bash", [script, issue.identifier],
              cd: repo_root,
              env: [{"SYMPHONY_REPO_ROOT", repo_root}],
              stderr_to_stdout: true
            )
          else
            {"Release script not found at #{script}", 127}
          end
      end

    release = parse_release_output(output, exit_code)

    case {exit_code, release.status} do
      {0, "production-ready"} -> {:ok, release}
      _ -> {:error, "Production release failed or did not confirm deployment.\n\n#{output}"}
    end
  end

  defp mark_production_deployed(%Issue{} = issue, release) do
    comment = """
    ## Production Release Summary

    Parent issue: #{issue.identifier || issue.id} / #{issue.title}
    PR: #{release.pr_url || "n/a"}
    Commit: #{release.commit_sha || "n/a"}
    Production: #{release.production_url || "n/a"}
    Deployment: #{release.deployment_id || "n/a"}

    Result: Production deployment confirmed.
    Decision needed: none
    """

    with :ok <- Tracker.add_labels(issue.id, ["Production Deployed"]),
         :ok <- Tracker.create_comment(issue.id, comment),
         :ok <- Tracker.update_issue_state(issue.id, "Done") do
      :ok
    else
      {:error, reason} -> {:error, "Could not mark production deployed: #{inspect(reason)}"}
    end
  end

  defp block_parent(%Issue{} = issue, reason) do
    comment = """
    ## Symphony Coordinator Required

    Parent issue: #{issue.identifier || issue.id} / #{issue.title}
    Result: Production release stopped safely.
    Reason: #{reason}
    Next step: fix the blocker, then keep `Production Approved` and remove `Coordinator Required` to retry.
    Decision needed: blocked
    """

    Tracker.add_labels(issue.id, ["Coordinator Required"])
    Tracker.create_comment(issue.id, comment)
    Tracker.update_issue_state(issue.id, "In Review")
    :ok
  end

  defp parse_release_output(output, exit_code) do
    %{
      exit_code: exit_code,
      output: output,
      status: capture_line(output, "Status"),
      pr_url: capture_line(output, "PR"),
      commit_sha: capture_line(output, "Commit"),
      production_url: capture_line(output, "Production"),
      deployment_id: capture_line(output, "Deployment")
    }
  end

  defp capture_line(output, label) do
    case Regex.run(~r/^#{Regex.escape(label)}:\s*(.+)$/m, output) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp label_set(%Issue{labels: labels}) when is_list(labels) do
    labels
    |> Enum.map(&normalize_label/1)
    |> MapSet.new()
  end

  defp label_set(_issue), do: MapSet.new()

  defp normalize_label(label) do
    label
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end
end
