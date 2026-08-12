defmodule CodeLead.WorkflowTest do
  # The characterisation guardrail for the workflow seam: the built-in
  # definition must reproduce architecture spec §4 exactly. The tables
  # below are transcribed from the spec, not from the implementation —
  # if a change to `CodeLead.Workflow` needs a change here, it is a
  # behaviour change and needs the spec updated with it.
  use ExUnit.Case, async: true

  alias CodeLead.Workflow
  alias CodeLead.Workflow.Stage

  # {key, stage_type, position}
  @stages [
    {:planning, :plan, 1},
    {:running, :execute, 2},
    {:review, :review, 3},
    {:done, :finalize, 4}
  ]

  # {from, to, trigger, context_policy, worktree_policy}
  @transitions [
    {:planning, :running, :human, :carry, :keep},
    {:running, :review, :auto, :carry, :keep},
    {:running, :planning, :human, :carry, :keep},
    {:review, :done, :human, :carry, :keep},
    {:review, :running, :human, :carry, :keep},
    {:review, :planning, :human, :reset, :discard}
  ]

  describe "the built-in workflow reproduces spec §4" do
    test "the four stages, their types, and their order" do
      stages = Workflow.built_in().stages

      assert Enum.map(stages, &{&1.key, &1.stage_type, &1.position}) == @stages
    end

    test "every edge carries the spec's trigger and policies" do
      workflow = Workflow.built_in()

      for {from, to, trigger, context_policy, worktree_policy} <- @transitions do
        assert {:ok, edge} = Workflow.fetch_transition(workflow, from, to)

        assert {edge.trigger, edge.context_policy, edge.worktree_policy} ==
                 {trigger, context_policy, worktree_policy},
               "#{from} → #{to} deviates from spec §4"
      end
    end

    test "there are no edges beyond the spec's" do
      actual = MapSet.new(Workflow.built_in().transitions, &{&1.from, &1.to})
      expected = MapSet.new(@transitions, fn {from, to, _t, _c, _w} -> {from, to} end)

      assert actual == expected
      assert length(Workflow.built_in().transitions) == length(@transitions)
    end

    test "only running → review is automatic" do
      auto = Enum.filter(Workflow.built_in().transitions, &(&1.trigger == :auto))

      assert [%{from: :running, to: :review}] = auto
    end

    test "the rework distinction: request changes carries, send back resets" do
      workflow = Workflow.built_in()

      assert {:ok, %{context_policy: :carry, worktree_policy: :keep}} =
               Workflow.fetch_transition(workflow, :review, :running)

      assert {:ok, %{context_policy: :reset, worktree_policy: :discard}} =
               Workflow.fetch_transition(workflow, :review, :planning)
    end

    test "moves outside the graph do not resolve" do
      workflow = Workflow.built_in()

      for {from, to} <- [
            {:planning, :done},
            {:planning, :review},
            {:running, :done},
            {:done, :review},
            {:done, :planning},
            {:running, :running}
          ] do
        assert :error = Workflow.fetch_transition(workflow, from, to),
               "#{from} → #{to} is not a spec §4 transition"
      end
    end

    test "cancelled is not a stage" do
      refute Workflow.stage(Workflow.built_in(), :cancelled)
    end
  end

  describe "lookups" do
    test "stage/2 resolves by key" do
      assert %Stage{stage_type: :execute, name: "Running"} =
               Workflow.stage(Workflow.built_in(), :running)

      refute Workflow.stage(Workflow.built_in(), :nope)
    end

    test "outgoing/2 lists a stage's edges" do
      review_targets =
        Workflow.built_in()
        |> Workflow.outgoing(:review)
        |> Enum.map(& &1.to)
        |> Enum.sort()

      assert review_targets == [:done, :planning, :running]
      assert Workflow.outgoing(Workflow.built_in(), :done) == []
    end

    test "fetch!/1 resolves the built-in key and rejects anything else" do
      assert Workflow.fetch!(Workflow.builtin_key()) == Workflow.built_in()
      assert_raise ArgumentError, fn -> Workflow.fetch!("nope") end
    end
  end

  describe "stage defaults" do
    test "a stage declared without a type is inert" do
      assert %Stage{stage_type: :custom} = %Stage{key: :holding, name: "Holding", position: 9}
    end
  end
end
