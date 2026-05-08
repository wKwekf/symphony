defmodule SymphonyElixir.CoordinatorV2Test do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{CoordinatorPlan, CoordinatorRunner, DeliveryRunner}

  test "fallback coordinator plan creates one worker child contract" do
    issue = %Issue{
      id: "parent-1",
      identifier: "HB-999",
      title: "Show interview questions in LiveKit call",
      description: "Render job interview questions in the call UI.",
      state: "Todo",
      labels: ["Agent Epic", "Frontend"]
    }

    assert {:ok, plan} = CoordinatorPlan.from_issue(issue)

    assert plan.mode == "single-worker"
    assert [child] = plan.children
    assert child.title =~ "HB-999 worker"
    assert "Agent Worker" in child.labels
    assert "Agent Ready" in child.labels
    assert child.ownership_area == "Frontend"
    assert plan.delivery.review_surface == "Vercel Preview"
  end

  test "preview environment epics are split into bounded worker children" do
    issue = %Issue{
      id: "parent-preview",
      identifier: "HB-201",
      title: "[HB-OPS] automate seeded Preview review environments",
      description:
        "Make Supabase Preview branches, Vercel Preview URLs, and seeded personas reliable for Daniel's review flow.",
      state: "Todo",
      labels: ["Agent Epic", "Backend"]
    }

    assert {:ok, plan} = CoordinatorPlan.from_issue(issue)

    assert plan.mode == "split"
    assert length(plan.children) == 2
    assert Enum.any?(plan.children, &String.contains?(&1.title, "preview seed command"))
    assert Enum.any?(plan.children, &String.contains?(&1.title, "preview review contract"))
    assert Enum.all?(plan.children, &("Agent Worker" in &1.labels))
    assert Enum.all?(plan.children, &("Agent Ready" in &1.labels))
    assert plan.delivery.persona_needed == true
    assert plan.delivery.review_surface =~ "Vercel Preview"
  end

  test "review instructions mentioning preview do not trigger preview environment plan" do
    issue = %Issue{
      id: "parent-submission-slug",
      identifier: "HB-206",
      title: "[HB-FRONTEND] show agent reference slug on submission detail",
      labels: ["Agent Epic", "Frontend", "MVP", "Feature"],
      description: """
      ## Context

      Daniel wants a stable agent reference slug in the Submission Detail view.

      ## Problem

      Agents need a concise way to identify the exact submission.

      ## Scope

      Show a copyable agent reference near the top of the Submission Detail view.

      ## Acceptance Criteria

      - The parent handoff includes a Vercel Preview URL, persona to use, and exact review steps.

      ## Test Plan

      1. Open the Vercel Preview URL.
      2. Use `/dev/personas` and choose the Staff persona.
      """
    }

    assert {:ok, plan} = CoordinatorPlan.from_issue(issue)

    assert plan.mode == "single-worker"
    assert [child] = plan.children
    refute String.contains?(child.title, "preview seed command")
    refute String.contains?(child.scope, "Own only the preview persona seeding path")
    assert child.ownership_area == "Frontend"
  end

  test "coordinator creates agent-ready child issues for a parent epic" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    parent = %Issue{
      id: "parent-create",
      identifier: "HB-1000",
      title: "Implement one small requirement",
      description: "Make the requirement reviewable.",
      state: "Todo",
      labels: ["Agent Epic"],
      children: []
    }

    assert :ok = CoordinatorRunner.run(parent)

    assert_receive {:memory_tracker_labels_ensured, labels}
    assert "Agent Epic" in labels

    assert_receive {:memory_tracker_state_update, "parent-create", "In Progress"}
    assert_receive {:memory_tracker_issue_created, %Issue{} = child}
    assert child.parent == %{id: "parent-create"}
    assert "Agent Worker" in child.labels
    assert "Agent Ready" in child.labels

    assert_receive {:memory_tracker_comment, "parent-create", comment}
    assert comment =~ "Symphony Coordinator Plan"
    assert comment =~ "Coordinator will wait"
  end

  test "coordinator ignores canceled blocked child issues when deciding parent blockers" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "child-canceled",
        identifier: "HB-200",
        title: "Obsolete worker",
        state: "Canceled",
        labels: ["Agent Worker", "Coordinator Required"]
      },
      %Issue{
        id: "child-active",
        identifier: "HB-201",
        title: "Active worker",
        state: "Todo",
        labels: ["Agent Worker", "Agent Ready"]
      }
    ])

    parent = %Issue{
      id: "parent-ignore",
      identifier: "HB-1003",
      title: "Parent with obsolete child",
      description: "Continue only with active children.",
      state: "In Progress",
      labels: ["Agent Epic"],
      children: [%{id: "child-canceled"}, %{id: "child-active"}]
    }

    assert :ok = CoordinatorRunner.run(parent)

    assert_receive {:memory_tracker_labels_ensured, _labels}
    refute_receive {:memory_tracker_labels_added, "parent-ignore", ["Coordinator Required"]}, 50
    refute_receive {:memory_tracker_comment, "parent-ignore", _comment}, 50
  end

  test "coordinator regenerates child issues when previous split children are canceled" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "child-preview-seed",
        identifier: "HB-207",
        title: "Canceled wrong child",
        state: "Canceled",
        labels: ["Agent Worker", "Agent Ready"]
      },
      %Issue{
        id: "child-preview-docs",
        identifier: "HB-208",
        title: "Canceled wrong child",
        state: "Canceled",
        labels: ["Agent Worker", "Agent Ready"]
      }
    ])

    parent = %Issue{
      id: "parent-regenerate",
      identifier: "HB-206",
      title: "[HB-FRONTEND] show agent reference slug on submission detail",
      description: """
      ## Context

      Daniel wants a stable agent reference slug in the Submission Detail view.

      ## Scope

      Show a copyable agent reference near the top of the Submission Detail view.

      ## Test Plan

      Open the Vercel Preview URL and review with seeded personas.
      """,
      state: "Todo",
      labels: ["Agent Epic", "Frontend"],
      children: [%{id: "child-preview-seed"}, %{id: "child-preview-docs"}]
    }

    assert :ok = CoordinatorRunner.run(parent)

    assert_receive {:memory_tracker_labels_ensured, _labels}
    assert_receive {:memory_tracker_state_update, "parent-regenerate", "In Progress"}
    assert_receive {:memory_tracker_issue_created, %Issue{} = child}
    assert child.parent == %{id: "parent-regenerate"}
    assert child.title =~ "HB-206 worker"
    refute String.contains?(child.title, "preview seed command")
    assert "Agent Worker" in child.labels
    assert "Agent Ready" in child.labels
  end

  test "clarification plan adds needs shaping and stops" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    parent = %Issue{
      id: "parent-clarify",
      identifier: "HB-1001",
      title: "Ambiguous parent",
      description: ~s({"mode":"clarify","questions":["Which persona should Daniel review?"]}),
      state: "Todo",
      labels: ["Agent Epic"],
      children: []
    }

    assert :ok = CoordinatorRunner.run(parent)

    assert_receive {:memory_tracker_labels_ensured, _labels}
    assert_receive {:memory_tracker_comment, "parent-clarify", comment}
    assert comment =~ "Needs Shaping"
    assert comment =~ "Which persona should Daniel review?"
    assert_receive {:memory_tracker_labels_added, "parent-clarify", ["Needs Shaping"]}
    assert_receive {:memory_tracker_state_update, "parent-clarify", "In Review"}
  end

  test "delivery without children marks parent coordinator required" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    parent = %Issue{
      id: "parent-delivery-blocked",
      identifier: "HB-1002",
      title: "Deliver parent",
      description: "Needs delivery.",
      state: "In Progress",
      labels: ["Agent Epic"],
      children: []
    }

    assert :ok = DeliveryRunner.run(parent)

    assert_receive {:memory_tracker_labels_added, "parent-delivery-blocked", ["Coordinator Required"]}
    assert_receive {:memory_tracker_comment, "parent-delivery-blocked", comment}
    assert comment =~ "Delivery stopped safely"
    assert_receive {:memory_tracker_state_update, "parent-delivery-blocked", "In Review"}
  end

  test "delivery ignores canceled child issues before publishing" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    parent = %Issue{
      id: "parent-canceled-child",
      identifier: "HB-1003",
      title: "Deliver parent with obsolete child",
      description: "Needs delivery.",
      state: "In Progress",
      labels: ["Agent Epic"],
      children: [
        %{id: "child-canceled", identifier: "HB-1004", state: "Canceled", branch_name: "codex/old"}
      ]
    }

    assert :ok = DeliveryRunner.run(parent)

    assert_receive {:memory_tracker_labels_added, "parent-canceled-child", ["Coordinator Required"]}
    assert_receive {:memory_tracker_comment, "parent-canceled-child", comment}
    assert comment =~ "Parent has no active child issues to integrate"
    refute comment =~ "codex/old"
    assert_receive {:memory_tracker_state_update, "parent-canceled-child", "In Review"}
  end

  test "delivery preview API URL uses Supabase ref instead of Vercel preview URL" do
    previous_api_url = System.get_env("SYMPHONY_PREVIEW_API_URL")
    previous_ref = System.get_env("SYMPHONY_PREVIEW_SUPABASE_REF")

    on_exit(fn ->
      restore_env("SYMPHONY_PREVIEW_API_URL", previous_api_url)
      restore_env("SYMPHONY_PREVIEW_SUPABASE_REF", previous_ref)
    end)

    System.delete_env("SYMPHONY_PREVIEW_API_URL")
    System.put_env("SYMPHONY_PREVIEW_SUPABASE_REF", "preview-ref-123")

    assert {:ok, "https://preview-ref-123.supabase.co/functions/v1/api"} =
             DeliveryRunner.preview_api_url_for_test()
  end

  test "delivery preview API URL refuses unsafe Vercel URL fallback" do
    previous_api_url = System.get_env("SYMPHONY_PREVIEW_API_URL")
    previous_ref = System.get_env("SYMPHONY_PREVIEW_SUPABASE_REF")

    on_exit(fn ->
      restore_env("SYMPHONY_PREVIEW_API_URL", previous_api_url)
      restore_env("SYMPHONY_PREVIEW_SUPABASE_REF", previous_ref)
    end)

    System.delete_env("SYMPHONY_PREVIEW_API_URL")
    System.delete_env("SYMPHONY_PREVIEW_SUPABASE_REF")

    assert {:error, reason} = DeliveryRunner.preview_api_url_for_test()
    assert reason =~ "Refusing to seed via the Vercel Preview app URL"
  end
end
