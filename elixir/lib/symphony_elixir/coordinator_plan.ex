defmodule SymphonyElixir.CoordinatorPlan do
  @moduledoc """
  Builds the Symphony v2 parent-to-child delivery plan.

  This module is intentionally deterministic for the first v2 slice. The
  Coordinator may later call an LLM to produce the same JSON contract, but this
  parser/fallback keeps orchestration safe and idempotent.
  """

  alias SymphonyElixir.Linear.Issue

  @default_child_labels ["Agent Worker", "Agent Ready", "Difficulty: Standard"]

  @type child_spec :: %{
          required(:title) => String.t(),
          required(:scope) => String.t(),
          required(:out_of_scope) => String.t(),
          required(:acceptance_criteria) => [String.t()],
          required(:test_plan) => [String.t()],
          required(:ownership_area) => String.t(),
          required(:labels) => [String.t()],
          required(:risk) => String.t(),
          required(:dependencies) => [String.t()]
        }

  @type delivery_spec :: %{
          required(:review_surface) => String.t(),
          required(:persona) => String.t(),
          required(:persona_needed) => boolean(),
          required(:validation_expectations) => [String.t()],
          required(:changelog_impact) => String.t(),
          required(:steps_to_test) => [String.t()]
        }

  @type plan :: %{
          required(:mode) => String.t(),
          required(:questions) => [String.t()],
          required(:children) => [child_spec()],
          required(:delivery) => delivery_spec()
        }

  @spec from_issue(Issue.t()) :: {:ok, plan()} | {:error, term()}
  def from_issue(%Issue{} = issue) do
    issue
    |> embedded_json_plan()
    |> case do
      {:ok, plan} -> normalize_plan(plan, issue)
      :none -> {:ok, fallback_plan(issue)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec child_description(Issue.t(), child_spec(), delivery_spec()) :: String.t()
  def child_description(%Issue{} = parent, child, delivery) when is_map(child) and is_map(delivery) do
    """
    ## Context

    Parent issue: #{parent.identifier || parent.id} / #{parent.title}

    This is a Symphony v2 worker child issue. Implement only this child scope.

    ## Scope

    #{child.scope}

    ## Out of Scope

    #{child.out_of_scope}

    ## Acceptance Criteria

    #{bullets(child.acceptance_criteria)}

    ## Test Plan

    #{bullets(child.test_plan)}

    ## Ownership

    Area: #{child.ownership_area}
    Risk: #{child.risk}
    Dependencies: #{inline_list(child.dependencies)}

    ## Worker Contract

    - Work in the isolated Symphony worktree/branch.
    - Do not publish the parent PR or seed Preview.
    - Write a concise handoff for the Coordinator.
    - Add a Linear comment with `Decision needed: coordinator`.
    - Move this child issue to `In Review` only when the scoped implementation is ready for Coordinator integration.

    ## Review Surface

    Coordinator delivery target: #{delivery.review_surface}
    Persona: #{delivery.persona}
    Changelog impact: #{delivery.changelog_impact}
    """
  end

  defp embedded_json_plan(%Issue{description: description}) when is_binary(description) do
    candidates =
      [
        fenced_json(description),
        trimmed_json(description)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find_value(candidates, :none, fn candidate ->
      case Jason.decode(candidate) do
        {:ok, %{} = plan} -> {:ok, plan}
        {:error, reason} -> {:error, {:invalid_plan_json, reason}}
        _ -> nil
      end
    end)
  end

  defp embedded_json_plan(_issue), do: :none

  defp fenced_json(description) do
    case Regex.run(~r/```(?:json)?\s*(\{.*?\})\s*```/s, description) do
      [_, json] -> json
      _ -> nil
    end
  end

  defp trimmed_json(description) do
    trimmed = String.trim(description)

    if String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}") do
      trimmed
    end
  end

  defp normalize_plan(plan, issue) when is_map(plan) do
    mode =
      plan
      |> get_value("mode", :mode, "single-worker")
      |> to_string()
      |> String.trim()

    questions =
      plan
      |> get_value("questions", :questions, [])
      |> normalize_string_list()

    children =
      plan
      |> get_value("children", :children, [])
      |> normalize_children(issue)

    delivery =
      plan
      |> get_value("delivery", :delivery, %{})
      |> normalize_delivery(issue)

    cond do
      mode == "clarify" and questions == [] ->
        {:error, :clarify_plan_missing_questions}

      mode in ["single-worker", "split"] and children == [] ->
        {:ok, %{fallback_plan(issue) | mode: mode, delivery: delivery}}

      mode in ["clarify", "single-worker", "split"] ->
        {:ok, %{mode: mode, questions: questions, children: children, delivery: delivery}}

      true ->
        {:error, {:unsupported_plan_mode, mode}}
    end
  end

  defp fallback_plan(%Issue{} = issue) do
    cond do
      preview_environment_issue?(issue) -> preview_environment_plan(issue)
      true -> single_worker_plan(issue)
    end
  end

  defp single_worker_plan(%Issue{} = issue) do
    ui_or_data = ui_or_data_issue?(issue)

    %{
      mode: "single-worker",
      questions: [],
      children: [
        %{
          title: child_title(issue),
          scope: issue.description || "Implement the parent issue request.",
          out_of_scope: "Production deploy, broad unrelated refactors, and unrelated cleanup.",
          acceptance_criteria: [
            "The parent request is implemented as one reviewable outcome.",
            "The change follows repository agent rules and tenant-safety constraints.",
            "The worker handoff explains what changed, validation, risks, and integration notes."
          ],
          test_plan: [
            "Run the relevant focused test or check for the changed area.",
            "If validation cannot be run, explain why in the worker handoff."
          ],
          ownership_area: inferred_area(issue),
          labels: Enum.uniq(@default_child_labels ++ inferred_area_labels(issue)),
          risk: inferred_risk(issue),
          dependencies: []
        }
      ],
      delivery: %{
        review_surface: "Vercel Preview",
        persona: if(ui_or_data, do: "staff or relevant /dev/personas entry", else: "not needed"),
        persona_needed: ui_or_data,
        validation_expectations: ["Coordinator integrates child branch and publishes one draft PR/Preview."],
        changelog_impact: "yes if product behavior changed; no for docs-only work",
        steps_to_test: ["Open the Preview URL.", "Follow the parent issue review steps."]
      }
    }
  end

  defp preview_environment_plan(%Issue{} = issue) do
    issue_ref = issue.identifier || "Parent"
    area_labels = inferred_area_labels(issue)

    %{
      mode: "split",
      questions: [],
      children: [
        %{
          title: "#{issue_ref} worker: harden preview seed command",
          scope: """
          Own only the preview persona seeding path. Update `scripts/seed-staging-personas.mjs` and focused script tests/docs only if required.

          Implement these outcomes:
          - `--branch-ref` must be functionally enforced, not only logged.
          - The seeder must refuse to run when the supplied base/API URL does not point at the expected Supabase preview ref.
          - Preview API examples must target Supabase Edge Functions (`https://<preview-ref>.supabase.co/functions/v1/api`), never a Vercel app URL.
          - Fresh preview setup must not require Daniel to manually invent a `WOLF_API_KEY` when service-role credentials are available; bootstrap or discover it idempotently, or fail with a precise blocker.
          - If the LiveKit/call-review smoke check fails, the command must exit blocked/not-review-ready instead of printing a successful Ready summary.
          """,
          out_of_scope:
            "Do not change Vercel project settings, Supabase production settings, unrelated seed data, Symphony orchestration, or deployment topology.",
          acceptance_criteria: [
            "`--branch-ref` changes runtime target validation behavior.",
            "A wrong Vercel app URL or wrong Supabase ref fails before mutating data.",
            "Fresh preview branches have an idempotent API-key/bootstrap path when required credentials are present.",
            "Call-review smoke failures produce a non-success result.",
            "The worker handoff lists exact command(s) Daniel/Coordinator should use."
          ],
          test_plan: [
            "Run the focused script test/dry-run path if available.",
            "Run a no-mutation/dry-run command that proves wrong preview target detection.",
            "If external credentials are required, document the exact unrun command and expected pass condition."
          ],
          ownership_area: "Backend",
          labels: Enum.uniq(@default_child_labels ++ area_labels ++ ["Backend"]),
          risk: "medium",
          dependencies: []
        },
        %{
          title: "#{issue_ref} worker: document preview review contract",
          scope: """
          Own only the reviewer-facing preview documentation. Update `docs/PREVIEW_ENVIRONMENTS.md`, `docs/AGENT_PREVIEW_REVIEW.md`, or `WORKFLOW.md` only where needed.

          Implement these outcomes:
          - Daniel gets one exact review flow: PR Preview URL, seeded persona, steps, expected result, and blocked states.
          - Docs state that Production is manual and Preview is the default finished state.
          - Docs reflect the correct Supabase Edge Functions host for preview seeding.
          - Docs explain what `Preview Ready`, `Coordinator Required`, and worker `In Review` mean.
          """,
          out_of_scope:
            "Do not edit application code, seed scripts, migrations, or platform credentials.",
          acceptance_criteria: [
            "The docs let Daniel test a Preview without Terminal archaeology.",
            "Examples distinguish Vercel Preview app URLs from Supabase preview API URLs.",
            "Coordinator/worker handoff states are documented in Daniel-readable language."
          ],
          test_plan: [
            "Review changed docs for command accuracy against the seed command contract.",
            "No app test required for docs-only changes; explain if docs reference unverified external URLs."
          ],
          ownership_area: "Docs",
          labels: Enum.uniq(["Agent Worker", "Agent Ready", "Difficulty: Easy", "Docs"]),
          risk: "low",
          dependencies: []
        }
      ],
      delivery: %{
        review_surface: "Vercel Preview plus seeded /dev/personas review flow",
        persona: "staff plus affected seeded persona from /dev/personas",
        persona_needed: true,
        validation_expectations: [
          "Coordinator integrates child branches into one parent delivery branch.",
          "Coordinator publishes one draft PR/Preview.",
          "Coordinator runs or documents the preview seed command for the PR target.",
          "Parent handoff includes Preview URL, persona, steps, validation, and blockers if any."
        ],
        changelog_impact: "yes if review workflow or preview tooling behavior changed",
        steps_to_test: [
          "Open the Vercel Preview URL.",
          "Open `/dev/personas` on that Preview.",
          "Login as the relevant persona and verify the seeded review path.",
          "Confirm the parent Linear issue contains Preview URL and exact review steps."
        ]
      }
    }
  end

  defp normalize_children(children, issue) when is_list(children) do
    children
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {%{} = child, index} -> [normalize_child(child, issue, index)]
      {_child, _index} -> []
    end)
  end

  defp normalize_children(_children, issue), do: fallback_plan(issue).children

  defp normalize_child(child, issue, index) do
    labels =
      child
      |> get_value("labels", :labels, [])
      |> normalize_string_list()
      |> then(&Enum.uniq(@default_child_labels ++ &1))

    %{
      title: get_string(child, "title", :title, "#{child_title(issue)} #{index}"),
      scope: get_string(child, "scope", :scope, issue.description || "Implement child scope."),
      out_of_scope: get_string(child, "out_of_scope", :out_of_scope, "Production deploy and unrelated work."),
      acceptance_criteria:
        child
        |> get_value("acceptance_criteria", :acceptance_criteria, [])
        |> normalize_string_list(["Scoped behavior is implemented and reviewable."]),
      test_plan:
        child
        |> get_value("test_plan", :test_plan, [])
        |> normalize_string_list(["Run relevant focused validation or explain why not run."]),
      ownership_area: get_string(child, "ownership_area", :ownership_area, inferred_area(issue)),
      labels: labels,
      risk: get_string(child, "risk", :risk, inferred_risk(issue)),
      dependencies:
        child
        |> get_value("dependencies", :dependencies, [])
        |> normalize_string_list()
    }
  end

  defp normalize_delivery(delivery, issue) when is_map(delivery) do
    persona = get_string(delivery, "persona", :persona, fallback_plan(issue).delivery.persona)
    persona_needed = truthy?(get_value(delivery, "persona_needed", :persona_needed, persona != "not needed"))

    %{
      review_surface: get_string(delivery, "review_surface", :review_surface, "Vercel Preview"),
      persona: persona,
      persona_needed: persona_needed,
      validation_expectations:
        delivery
        |> get_value("validation_expectations", :validation_expectations, [])
        |> normalize_string_list(["Coordinator publishes one draft PR/Preview."]),
      changelog_impact: get_string(delivery, "changelog_impact", :changelog_impact, "unknown"),
      steps_to_test:
        delivery
        |> get_value("steps_to_test", :steps_to_test, [])
        |> normalize_string_list(["Open the Preview URL.", "Follow the parent issue acceptance criteria."])
    }
  end

  defp normalize_delivery(_delivery, issue), do: fallback_plan(issue).delivery

  defp child_title(%Issue{identifier: identifier, title: title})
       when is_binary(identifier) and is_binary(title) do
    "#{identifier} worker: #{short_title(title)}"
  end

  defp child_title(%Issue{title: title}) when is_binary(title), do: "Worker: #{short_title(title)}"
  defp child_title(_issue), do: "Worker implementation"

  defp short_title(title) do
    title
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 90)
  end

  defp inferred_area(%Issue{} = issue) do
    labels = normalized_labels(issue)

    cond do
      "backend" in labels -> "Backend"
      "frontend" in labels -> "Frontend"
      "mcp" in labels -> "MCP"
      "docs" in labels -> "Docs"
      true -> "Implementation"
    end
  end

  defp inferred_area_labels(%Issue{} = issue) do
    labels = normalized_labels(issue)

    cond do
      "backend" in labels -> ["Backend"]
      "frontend" in labels -> ["Frontend"]
      "mcp" in labels -> ["MCP"]
      "docs" in labels -> ["Docs"]
      true -> []
    end
  end

  defp inferred_risk(%Issue{} = issue) do
    labels = normalized_labels(issue)

    if Enum.any?(labels, &(&1 in ["auth/rls", "migration", "high risk", "production data", "external email"])) do
      "high"
    else
      "medium"
    end
  end

  defp ui_or_data_issue?(%Issue{} = issue) do
    labels = normalized_labels(issue)
    body = String.downcase("#{issue.title || ""}\n#{issue.description || ""}")

    Enum.any?(labels, &(&1 in ["frontend", "backend", "feature", "bug"])) or
      String.contains?(body, "preview") or
      String.contains?(body, "persona") or
      String.contains?(body, "ui") or
      String.contains?(body, "daten")
  end

  defp preview_environment_issue?(%Issue{} = issue) do
    body = issue_body(issue)

    String.contains?(body, "preview") and
      Enum.any?(["seed", "persona", "supabase", "vercel", "environment", "umgebung"], &String.contains?(body, &1))
  end

  defp issue_body(%Issue{} = issue) do
    "#{issue.title || ""}\n#{issue.description || ""}"
    |> String.downcase()
  end

  defp normalized_labels(%Issue{labels: labels}) when is_list(labels) do
    Enum.map(labels, &String.downcase(to_string(&1)))
  end

  defp normalized_labels(_issue), do: []

  defp get_string(map, string_key, atom_key, default) do
    map
    |> get_value(string_key, atom_key, default)
    |> case do
      value when is_binary(value) -> non_empty_string(value, default)
      value when is_atom(value) -> value |> Atom.to_string() |> String.trim()
      value when is_integer(value) -> Integer.to_string(value)
      _ -> default
    end
  end

  defp non_empty_string(value, default) do
    trimmed = String.trim(value)
    if byte_size(trimmed) > 0, do: trimmed, else: default
  end

  defp get_value(map, string_key, atom_key, default) when is_map(map) do
    Map.get(map, string_key) || Map.get(map, atom_key) || default
  end

  defp normalize_string_list(value, default \\ [])

  defp normalize_string_list(values, default) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> default
      normalized -> normalized
    end
  end

  defp normalize_string_list(value, default) when is_binary(value) do
    value
    |> String.split(["\n", ";"], trim: true)
    |> normalize_string_list(default)
  end

  defp normalize_string_list(_value, default), do: default

  defp truthy?(value) when value in [true, "true", "yes", "needed", "1", 1], do: true
  defp truthy?(_value), do: false

  defp bullets([]), do: "- Not specified."
  defp bullets(items), do: Enum.map_join(items, "\n", &"- #{&1}")

  defp inline_list([]), do: "none"
  defp inline_list(items), do: Enum.join(items, ", ")
end
