defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.{Config, Linear.Issue}

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @project_context_query """
  query SymphonyProjectContext {
    projects(first: 100) {
      nodes {
        id
        name
        slugId
        teams(first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @team_state_lookup_query """
  query SymphonyResolveTeamStateId($teamId: String!, $stateName: String!) {
    team(id: $teamId) {
      states(filter: {name: {eq: $stateName}}, first: 1) {
        nodes {
          id
        }
      }
    }
  }
  """

  @issue_label_lookup_query """
  query SymphonyIssueLabels($issueId: String!) {
    issue(id: $issueId) {
      labels {
        nodes {
          id
          name
        }
      }
    }
  }
  """

  @label_lookup_query """
  query SymphonyLabelLookup($names: [String!]!) {
    issueLabels(filter: {name: {in: $names}}, first: 100) {
      nodes {
        id
        name
      }
    }
  }
  """

  @label_create_mutation """
  mutation SymphonyCreateIssueLabel($teamId: String!, $name: String!) {
    issueLabelCreate(input: {teamId: $teamId, name: $name, color: "#5E6AD2"}) {
      success
      issueLabel {
        id
        name
      }
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyCreateIssue($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        title
        description
        priority
        branchName
        url
        state {
          name
        }
        parent {
          id
          identifier
          state {
            name
          }
        }
        labels {
          nodes {
            name
          }
        }
      }
    }
  }
  """

  @update_labels_mutation """
  mutation SymphonyUpdateIssueLabels($issueId: String!, $labelIds: [String!]) {
    issueUpdate(id: $issueId, input: {labelIds: $labelIds}) {
      success
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec ensure_labels([String.t()]) :: {:ok, map()} | {:error, term()}
  def ensure_labels(label_names) when is_list(label_names) do
    names = normalize_label_names(label_names)

    with {:ok, %{team_id: team_id}} <- project_context(),
         {:ok, existing} <- lookup_labels(names) do
      Enum.reduce_while(names, {:ok, existing}, fn name, {:ok, acc} ->
        if Map.has_key?(acc, name) do
          {:cont, {:ok, acc}}
        else
          case create_label(team_id, name) do
            {:ok, label_id} -> {:cont, {:ok, Map.put(acc, name, label_id)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
      end)
    end
  end

  @spec add_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def add_labels(issue_id, label_names) when is_binary(issue_id) and is_list(label_names) do
    names = normalize_label_names(label_names)

    with {:ok, desired_label_ids_by_name} <- ensure_labels(names),
         {:ok, current_label_ids} <- current_issue_label_ids(issue_id),
         label_ids <- Enum.uniq(current_label_ids ++ Map.values(desired_label_ids_by_name)),
         {:ok, response} <-
           client_module().graphql(@update_labels_mutation, %{issueId: issue_id, labelIds: label_ids}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_label_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_label_update_failed}
    end
  end

  @spec create_issue(map()) :: {:ok, Issue.t()} | {:error, term()}
  def create_issue(attrs) when is_map(attrs) do
    labels = normalize_label_names(Map.get(attrs, :labels) || Map.get(attrs, "labels") || [])
    state_name = Map.get(attrs, :state) || Map.get(attrs, "state") || "Todo"

    with title when is_binary(title) and byte_size(title) > 0 <-
           Map.get(attrs, :title) || Map.get(attrs, "title"),
         {:ok, %{project_id: project_id, team_id: team_id}} <- project_context(),
         {:ok, state_id} <- resolve_team_state_id(team_id, state_name),
         {:ok, label_ids_by_name} <- ensure_labels(labels),
         input <- create_issue_input(attrs, title, project_id, team_id, state_id, Map.values(label_ids_by_name)),
         {:ok, response} <- client_module().graphql(@create_issue_mutation, %{input: input}),
         true <- get_in(response, ["data", "issueCreate", "success"]) == true,
         %{} = issue <- get_in(response, ["data", "issueCreate", "issue"]) do
      {:ok, normalize_created_issue(issue)}
    else
      nil -> {:error, :missing_issue_title}
      false -> {:error, :issue_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_create_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp project_context do
    project_slug = Config.settings!().tracker.project_slug

    with slug when is_binary(slug) and byte_size(slug) > 0 <- project_slug,
         {:ok, response} <- client_module().graphql(@project_context_query, %{}),
         %{"id" => project_id, "teams" => %{"nodes" => [%{"id" => team_id} | _]}} <-
           find_project_context_node(response, slug) do
      {:ok, %{project_id: project_id, team_id: team_id}}
    else
      nil -> {:error, :missing_linear_project_slug}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :linear_project_context_not_found}
    end
  end

  defp find_project_context_node(response, slug) do
    response
    |> get_in(["data", "projects", "nodes"])
    |> case do
      projects when is_list(projects) -> Enum.find(projects, &project_matches?(&1, slug))
      _ -> nil
    end
  end

  defp project_matches?(%{} = project, wanted) when is_binary(wanted) do
    normalized_wanted = normalize_project_lookup(wanted)
    id = normalize_project_lookup(project["id"])
    name = normalize_project_lookup(project["name"])
    slug_id = normalize_project_lookup(project["slugId"])
    slug_name = project_slug_name(project["name"])

    normalized_wanted in [id, name, slug_id, "#{slug_name}-#{slug_id}"] or
      String.ends_with?(normalized_wanted, "-#{slug_id}")
  end

  defp project_matches?(_project, _wanted), do: false

  defp normalize_project_lookup(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_project_lookup(_value), do: ""

  defp project_slug_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp project_slug_name(_name), do: ""

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp resolve_team_state_id(team_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@team_state_lookup_query, %{teamId: team_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp lookup_labels([]), do: {:ok, %{}}

  defp lookup_labels(names) do
    with {:ok, response} <- client_module().graphql(@label_lookup_query, %{names: names}),
         labels when is_list(labels) <- get_in(response, ["data", "issueLabels", "nodes"]) do
      {:ok,
       Map.new(labels, fn label ->
         {label["name"], label["id"]}
       end)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_lookup_failed}
    end
  end

  defp create_label(team_id, name) do
    with {:ok, response} <- client_module().graphql(@label_create_mutation, %{teamId: team_id, name: name}),
         true <- get_in(response, ["data", "issueLabelCreate", "success"]) == true,
         label_id when is_binary(label_id) <- get_in(response, ["data", "issueLabelCreate", "issueLabel", "id"]) do
      {:ok, label_id}
    else
      false -> {:error, :label_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_create_failed}
    end
  end

  defp current_issue_label_ids(issue_id) do
    with {:ok, response} <- client_module().graphql(@issue_label_lookup_query, %{issueId: issue_id}),
         labels when is_list(labels) <- get_in(response, ["data", "issue", "labels", "nodes"]) do
      {:ok, Enum.flat_map(labels, &label_id/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_label_lookup_failed}
    end
  end

  defp label_id(%{"id" => id}) when is_binary(id), do: [id]
  defp label_id(_), do: []

  defp normalize_label_names(label_names) do
    label_names
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp create_issue_input(attrs, title, project_id, team_id, state_id, label_ids) do
    input = %{
      title: title,
      teamId: team_id,
      projectId: project_id,
      stateId: state_id,
      labelIds: label_ids
    }

    input
    |> maybe_put(:description, Map.get(attrs, :description) || Map.get(attrs, "description"))
    |> maybe_put(:parentId, Map.get(attrs, :parent_id) || Map.get(attrs, "parent_id"))
    |> maybe_put(:priority, Map.get(attrs, :priority) || Map.get(attrs, "priority"))
  end

  defp maybe_put(input, _key, nil), do: input
  defp maybe_put(input, _key, ""), do: input
  defp maybe_put(input, key, value), do: Map.put(input, key, value)

  defp normalize_created_issue(issue) do
    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: issue["priority"],
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      parent: normalize_parent(issue["parent"]),
      labels: normalize_created_issue_labels(issue)
    }
  end

  defp normalize_parent(%{} = parent) do
    %{
      id: parent["id"],
      identifier: parent["identifier"],
      state: get_in(parent, ["state", "name"])
    }
  end

  defp normalize_parent(_parent), do: nil

  defp normalize_created_issue_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    Enum.flat_map(labels, fn
      %{"name" => name} when is_binary(name) -> [String.downcase(name)]
      _ -> []
    end)
  end

  defp normalize_created_issue_labels(_issue), do: []
end
