defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  @spec ensure_labels([String.t()]) :: {:ok, map()} | {:error, term()}
  def ensure_labels(label_names) when is_list(label_names) do
    labels =
      label_names
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Map.new(fn label -> {label, "label-#{String.downcase(String.replace(label, " ", "-"))}"} end)

    send_event({:memory_tracker_labels_ensured, Map.keys(labels)})
    {:ok, labels}
  end

  @spec add_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def add_labels(issue_id, label_names) when is_binary(issue_id) and is_list(label_names) do
    send_event({:memory_tracker_labels_added, issue_id, label_names})
    :ok
  end

  @spec create_issue(map()) :: {:ok, Issue.t()} | {:error, term()}
  def create_issue(attrs) when is_map(attrs) do
    title = Map.get(attrs, :title) || Map.get(attrs, "title")
    parent_id = Map.get(attrs, :parent_id) || Map.get(attrs, "parent_id")

    issue = %Issue{
      id: Map.get(attrs, :id) || Map.get(attrs, "id") || "memory-#{System.unique_integer([:positive])}",
      identifier: Map.get(attrs, :identifier) || Map.get(attrs, "identifier") || "MT-#{System.unique_integer([:positive])}",
      title: title,
      description: Map.get(attrs, :description) || Map.get(attrs, "description"),
      priority: Map.get(attrs, :priority) || Map.get(attrs, "priority"),
      state: Map.get(attrs, :state) || Map.get(attrs, "state") || "Todo",
      parent: if(is_binary(parent_id), do: %{id: parent_id}, else: nil),
      labels: Map.get(attrs, :labels) || Map.get(attrs, "labels") || []
    }

    send_event({:memory_tracker_issue_created, issue})
    {:ok, issue}
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
