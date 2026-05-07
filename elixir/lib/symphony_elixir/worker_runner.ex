defmodule SymphonyElixir.WorkerRunner do
  @moduledoc """
  Symphony v2 worker runner.

  Workers execute child issues only. The current implementation delegates to the
  existing Codex-backed AgentRunner while the orchestrator controls which issues
  are eligible.
  """

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok
  def run(%Issue{} = issue, recipient \\ nil, opts \\ []) do
    AgentRunner.run(issue, recipient, opts)
  end
end
