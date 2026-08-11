defmodule CodeLeadWeb.TaskLive.AgentFeedBlocksTest do
  use ExUnit.Case, async: true

  alias CodeLead.AgentFeed.AgentEvent
  alias CodeLeadWeb.TaskLive.AgentFeedBlocks

  defp row(id, kind, attrs \\ %{}) do
    struct(%AgentEvent{id: id, kind: kind, data: %{}}, attrs)
  end

  describe "fold/2" do
    test "groups consecutive tool calls and splits on anything else" do
      rows = [
        row(1, :run_started),
        row(2, :tool_call),
        row(3, :tool_call),
        row(4, :message),
        row(5, :tool_call)
      ]

      assert [
               %{id: 1, kind: :notice},
               %{id: 2, kind: :tools, rows: [_first, _second]},
               %{id: 4, kind: :message},
               %{id: 5, kind: :tools}
             ] = AgentFeedBlocks.fold(rows, false)
    end

    test "leaves the trailing group expanded only while executing" do
      rows = [row(1, :tool_call)]

      assert [%{expanded?: true}] = AgentFeedBlocks.fold(rows, true)
      assert [%{expanded?: false}] = AgentFeedBlocks.fold(rows, false)
    end

    test "does not expand a trailing group that is not the last block" do
      rows = [row(1, :tool_call), row(2, :message)]

      assert [%{expanded?: false}, %{kind: :message}] = AgentFeedBlocks.fold(rows, true)
    end
  end

  describe "apply_row/2" do
    test "a known row is replaced in place and reported as the only change" do
      blocks = AgentFeedBlocks.fold([row(1, :tool_call), row(2, :tool_call)], true)
      updated = row(2, :tool_call, %{text: "done"})

      assert {[block], [changed]} = AgentFeedBlocks.apply_row(blocks, updated)
      assert changed == block
      assert [%{id: 1}, %{id: 2, text: "done"}] = block.rows
    end

    test "a new tool call extends the open group" do
      blocks = AgentFeedBlocks.fold([row(1, :tool_call)], true)

      assert {[block], [changed]} = AgentFeedBlocks.apply_row(blocks, row(2, :tool_call))
      assert changed == block
      assert length(block.rows) == 2
    end

    test "a non-tool row closes and collapses the open group" do
      blocks = AgentFeedBlocks.fold([row(1, :tool_call)], true)

      assert {[group, message], [collapsed, message]} =
               AgentFeedBlocks.apply_row(blocks, row(2, :message))

      assert group.expanded? == false
      assert collapsed.id == 1
      assert message.kind == :message
    end

    test "a pinned group is never auto-collapsed" do
      blocks = AgentFeedBlocks.fold([row(1, :tool_call)], true)
      {blocks, _block} = AgentFeedBlocks.toggle(blocks, 1)
      {blocks, _block} = AgentFeedBlocks.toggle(blocks, 1)

      assert {[group, _new], [_changed]} = AgentFeedBlocks.apply_row(blocks, row(2, :message))
      assert group.expanded?
    end
  end

  describe "toggle/2" do
    test "flips and pins the block, ignoring unknown ids" do
      blocks = AgentFeedBlocks.fold([row(1, :tool_call)], false)

      assert {[%{expanded?: true, pinned?: true}], %{id: 1}} = AgentFeedBlocks.toggle(blocks, 1)
      assert {^blocks, nil} = AgentFeedBlocks.toggle(blocks, 99)
    end
  end
end
