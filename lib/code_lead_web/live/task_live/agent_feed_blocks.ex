defmodule CodeLeadWeb.TaskLive.AgentFeedBlocks do
  @moduledoc """
  Folds an ordered executor transcript into the display blocks the Agent
  tab streams: consecutive tool calls collapse into one group, every
  other row stands alone.

  Blocks are identified by their first row's id, so a block keeps its
  DOM position when it is re-inserted to gain a member, to advance a
  tool's status, or to collapse.
  """

  alias CodeLead.AgentFeed.AgentEvent

  @type block :: %{
          id: pos_integer(),
          kind: :tools | :message | :notice,
          rows: [AgentEvent.t()],
          expanded?: boolean(),
          pinned?: boolean()
        }

  @doc """
  Folds a whole transcript. The trailing tool group is left expanded
  while the run is still executing.
  """
  @spec fold([AgentEvent.t()], boolean()) :: [block()]
  def fold(rows, executing?) do
    rows
    |> Enum.reduce([], &add_row/2)
    |> Enum.reverse()
    |> expand_last(executing?)
  end

  @doc """
  Applies one row to already-folded blocks, returning the new list and
  only the blocks that changed (what the caller re-inserts into the
  stream). A row whose id is already known replaces itself in place —
  that is how a tool call advances its status and how a finished message
  supersedes its streaming version.
  """
  @spec apply_row([block()], AgentEvent.t()) :: {[block()], [block()]}
  def apply_row(blocks, %AgentEvent{} = row) do
    case Enum.split_while(blocks, &(not member?(&1, row.id))) do
      {_before, []} ->
        append_row(blocks, row)

      {before, [block | rest]} ->
        updated = replace_row(block, row)
        {before ++ [updated | rest], [updated]}
    end
  end

  @doc """
  Whether a row already sits in a block — the caller's cue that an
  incoming row updates in place rather than arriving for the first time.
  """
  @spec known?([block()], pos_integer()) :: boolean()
  def known?(blocks, row_id), do: Enum.any?(blocks, &member?(&1, row_id))

  @doc """
  Toggles a block's collapse state and pins it, so auto-collapse leaves
  it alone from then on.
  """
  @spec toggle([block()], pos_integer()) :: {[block()], block() | nil}
  def toggle(blocks, id) do
    case Enum.find(blocks, &(&1.id == id)) do
      nil ->
        {blocks, nil}

      block ->
        toggled = %{block | expanded?: not block.expanded?, pinned?: true}
        {Enum.map(blocks, &if(&1.id == id, do: toggled, else: &1)), toggled}
    end
  end

  defp add_row(%AgentEvent{kind: :tool_call} = row, [%{kind: :tools} = block | rest]) do
    [%{block | rows: block.rows ++ [row]} | rest]
  end

  defp add_row(row, blocks), do: [new_block(row) | blocks]

  defp new_block(%AgentEvent{kind: kind, id: id} = row) do
    %{id: id, kind: block_kind(kind), rows: [row], expanded?: false, pinned?: false}
  end

  defp block_kind(:tool_call), do: :tools
  defp block_kind(:message), do: :message
  defp block_kind(_kind), do: :notice

  defp expand_last(blocks, false), do: blocks

  defp expand_last(blocks, true) do
    case List.last(blocks) do
      %{kind: :tools} = last -> List.replace_at(blocks, -1, %{last | expanded?: true})
      _other -> blocks
    end
  end

  defp member?(%{rows: rows}, row_id), do: Enum.any?(rows, &(&1.id == row_id))

  defp replace_row(%{rows: rows} = block, row) do
    %{block | rows: Enum.map(rows, &if(&1.id == row.id, do: row, else: &1))}
  end

  # A tool call extends the open group; anything else closes it, which is
  # when an unpinned group collapses.
  defp append_row(blocks, %AgentEvent{kind: :tool_call} = row) do
    case List.last(blocks) do
      %{kind: :tools} = last ->
        extended = %{last | rows: last.rows ++ [row]}
        {List.replace_at(blocks, -1, extended), [extended]}

      _other ->
        start_block(blocks, %{new_block(row) | expanded?: true})
    end
  end

  defp append_row(blocks, row), do: start_block(blocks, new_block(row))

  defp start_block(blocks, block) do
    case List.last(blocks) do
      %{kind: :tools, expanded?: true, pinned?: false} = last ->
        collapsed = %{last | expanded?: false}
        {List.replace_at(blocks, -1, collapsed) ++ [block], [collapsed, block]}

      _other ->
        {blocks ++ [block], [block]}
    end
  end
end
