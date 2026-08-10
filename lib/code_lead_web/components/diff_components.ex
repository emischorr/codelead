defmodule CodeLeadWeb.DiffComponents do
  @moduledoc """
  Renders parsed diffs (`CodeLead.Git.Diff`) in the design language:
  file list with per-file counts, sticky file headers, dual line-number
  gutters, and add/del row tints.
  """
  use Phoenix.Component

  alias CodeLead.Git.DiffFile

  @doc """
  Renders the changed-files sidebar list. Entries link to per-file
  anchors inside the diff pane.
  """
  attr :files, :list, required: true
  attr :stats, :map, required: true

  def file_list(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex items-center justify-between px-2 pb-2">
        <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">
          {@stats.files} {if @stats.files == 1, do: "file", else: "files"} changed
        </span>
        <span class="font-mono text-[11px]">
          <span class="text-add-text">+{@stats.additions}</span>
          <span class="text-del-text">−{@stats.deletions}</span>
        </span>
      </div>
      <a
        :for={file <- @files}
        href={"#diff-file-#{file_dom_id(file)}"}
        class="flex items-center gap-2 rounded-[9px] px-2 py-1.5 hover:bg-surface2"
      >
        <span class="min-w-0 flex-1 truncate font-mono text-[11.5px] text-text2">
          {DiffFile.path(file)}
        </span>
        <span class="shrink-0 font-mono text-[10.5px]">
          <span class="text-add-text">+{file.additions}</span>
          <span class="text-del-text">−{file.deletions}</span>
        </span>
      </a>
    </div>
    """
  end

  @doc """
  Renders one file's diff: sticky mono header plus hunk rows.
  """
  attr :file, DiffFile, required: true

  def file_diff(assigns) do
    ~H"""
    <div
      id={"diff-file-#{file_dom_id(@file)}"}
      class="overflow-hidden rounded-xl border border-border"
    >
      <div class="sticky top-0 z-10 flex items-center gap-2.5 border-b border-border bg-surface2 px-4 py-2.5">
        <span class="min-w-0 truncate font-mono text-xs font-semibold text-text">
          {DiffFile.path(@file)}
        </span>
        <span :if={@file.status == :renamed} class="font-mono text-[10.5px] text-text3">
          renamed from {@file.old_path}
        </span>
        <span class="ml-auto shrink-0 font-mono text-[11px] text-text3">
          +{@file.additions} −{@file.deletions}
        </span>
      </div>
      <div :if={@file.binary?} class="bg-surface px-4 py-6 text-center text-xs text-text3">
        Binary file — no text diff.
      </div>
      <div
        :if={@file.hunks == [] && !@file.binary?}
        class="bg-surface px-4 py-6 text-center text-xs text-text3"
      >
        No content changes.
      </div>
      <div :if={@file.hunks != []} class="overflow-x-auto bg-surface">
        <table class="w-full border-collapse font-mono text-xs leading-relaxed">
          <tbody>
            <%= for hunk <- @file.hunks do %>
              <tr class="bg-surface2 text-text3">
                <td class="w-10 select-none px-2" colspan="2"></td>
                <td class="whitespace-pre px-4 py-0.5">{hunk.header}</td>
              </tr>
              <.diff_row :for={line <- hunk.lines} line={line} />
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :line, :map, required: true

  defp diff_row(assigns) do
    ~H"""
    <tr class={row_class(@line.type)}>
      <td class="w-10 select-none whitespace-nowrap pr-2.5 text-right tabular-nums opacity-60">
        {@line.old_no}
      </td>
      <td class="w-10 select-none whitespace-nowrap pr-2.5 text-right tabular-nums opacity-60">
        {@line.new_no}
      </td>
      <td class="whitespace-pre px-4">{line_prefix(@line.type)}{@line.text}</td>
    </tr>
    """
  end

  defp row_class(:add), do: "bg-add-bg text-add-text"
  defp row_class(:del), do: "bg-del-bg text-del-text"
  defp row_class(:ctx), do: "text-text"

  defp line_prefix(:add), do: "+"
  defp line_prefix(:del), do: "-"
  defp line_prefix(:ctx), do: " "

  defp file_dom_id(file) do
    file |> DiffFile.path() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
  end
end
