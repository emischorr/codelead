defmodule CodeLeadWeb.DiffComponents do
  @moduledoc """
  Renders parsed diffs (`CodeLead.Git.Diff`) in the design language:
  file list with per-file counts, sticky file headers, dual line-number
  gutters, and add/del row tints.
  """
  use Phoenix.Component

  import CodeLeadWeb.CoreComponents, only: [icon: 1]

  alias CodeLead.Git.DiffFile

  @doc """
  The DOM id of a file's diff card — the jump target. Base64 keeps it
  injective: a slug would collapse `a/b.ex` and `a-b.ex` onto one id.
  """
  @spec file_dom_id(String.t()) :: String.t()
  def file_dom_id(path), do: "diff-file-" <> Base.url_encode64(path, padding: false)

  @doc """
  Renders the changed-files sidebar list. Entries focus their file in
  the diff pane; the expanded one is marked active.
  """
  attr :files, :list, required: true
  attr :stats, :map, required: true
  attr :expanded, :any, required: true, doc: "MapSet of expanded file paths"

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
      <button
        :for={file <- @files}
        :key={DiffFile.path(file)}
        type="button"
        phx-click="focus_file"
        phx-value-path={DiffFile.path(file)}
        class={[
          "flex w-full items-center gap-2 rounded-[9px] px-2 py-1.5 text-left transition-colors",
          if(MapSet.member?(@expanded, DiffFile.path(file)),
            do: "bg-surface2 text-text",
            else: "hover:bg-surface2"
          )
        ]}
      >
        <span class="min-w-0 flex-1 truncate font-mono text-[11.5px] text-text2">
          {DiffFile.path(file)}
        </span>
        <span class="shrink-0 font-mono text-[10.5px]">
          <span class="text-add-text">+{file.additions}</span>
          <span class="text-del-text">−{file.deletions}</span>
        </span>
      </button>
    </div>
    """
  end

  @doc """
  Renders one file's diff: a sticky mono header that toggles the body,
  plus hunk rows. A collapsed file renders no rows at all.
  """
  attr :file, DiffFile, required: true
  attr :expanded?, :boolean, default: false

  def file_diff(assigns) do
    ~H"""
    <div
      id={file_dom_id(DiffFile.path(@file))}
      class="overflow-hidden rounded-xl border border-border"
    >
      <button
        type="button"
        phx-click="toggle_file"
        phx-value-path={DiffFile.path(@file)}
        aria-expanded={to_string(@expanded?)}
        class="sticky top-0 z-10 flex w-full items-center gap-2.5 border-b border-border bg-surface2 px-4 py-2.5 text-left hover:bg-surface"
      >
        <.icon
          name="hero-chevron-right"
          class={["size-3.5 shrink-0 text-text3 transition-transform", @expanded? && "rotate-90"]}
        />
        <span class="min-w-0 truncate font-mono text-xs font-semibold text-text">
          {DiffFile.path(@file)}
        </span>
        <span :if={@file.status == :renamed} class="font-mono text-[10.5px] text-text3">
          renamed from {@file.old_path}
        </span>
        <span class="ml-auto shrink-0 font-mono text-[11px] text-text3">
          +{@file.additions} −{@file.deletions}
        </span>
      </button>
      <div
        :if={@expanded? && @file.binary?}
        class="bg-surface px-4 py-6 text-center text-xs text-text3"
      >
        Binary file — no text diff.
      </div>
      <div
        :if={@expanded? && @file.hunks == [] && !@file.binary?}
        class="bg-surface px-4 py-6 text-center text-xs text-text3"
      >
        No content changes.
      </div>
      <div :if={@expanded? && @file.hunks != []} class="overflow-x-auto bg-surface">
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
end
