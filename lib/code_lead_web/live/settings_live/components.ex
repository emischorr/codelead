defmodule CodeLeadWeb.SettingsLive.Components do
  @moduledoc """
  The primitives the settings pages share: the page header, the overview
  tile, the list row that stands in for a table, the modal that hosts the
  create/edit forms, and the guarded delete button.

  These are deliberately local rather than promoted into `UIComponents` —
  `list_row/1` and `modal/1` are general enough to belong there eventually,
  but promoting them means refactoring `BoardLive`'s hand-rolled modal too.
  """

  use CodeLeadWeb, :html

  @doc """
  The standard 58px page header every settings surface opens with.
  """
  attr :title, :string, required: true
  attr :back, :string, default: nil
  slot :actions

  def settings_page_header(assigns) do
    ~H"""
    <header class="flex h-[58px] shrink-0 items-center gap-3.5 border-b border-border bg-surface px-4 sm:px-5">
      <Layouts.sidebar_toggle />
      <.link
        :if={@back}
        id="settings-back"
        navigate={@back}
        class="inline-flex size-8 items-center justify-center rounded-[9px] text-text3 hover:bg-surface2 hover:text-text2"
        title="Back"
      >
        <.icon name="hero-chevron-left" class="size-4" />
      </.link>
      <h1 class="min-w-0 truncate text-[15px] font-bold tracking-tight text-text">{@title}</h1>
      <div class="ml-auto flex items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  An overview tile. Without a `navigate` it renders as a disabled placeholder
  for a section that does not exist yet.
  """
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :stat, :string, required: true
  attr :detail, :string, default: nil
  attr :navigate, :string, default: nil

  def settings_tile(%{navigate: nil} = assigns) do
    ~H"""
    <div
      id={@id}
      class="flex cursor-not-allowed flex-col gap-2.5 rounded-[14px] border border-border bg-surface p-4 opacity-70"
      aria-disabled="true"
      title="Coming soon"
    >
      <.tile_body icon={@icon} label={@label} stat={@stat} detail={@detail} muted>
        <.badge variant={:neutral}>Coming soon</.badge>
      </.tile_body>
    </div>
    """
  end

  def settings_tile(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class="flex flex-col gap-2.5 rounded-[14px] border border-border bg-surface p-4 transition-colors hover:border-accent hover:bg-surface2"
    >
      <.tile_body icon={@icon} label={@label} stat={@stat} detail={@detail}>
        <.icon name="hero-chevron-right" class="size-4 text-text3" />
      </.tile_body>
    </.link>
    """
  end

  @doc """
  One entry in a settings list. Rendered inside a `<.section_card>`, which
  supplies the surrounding border and padding.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :navigate, :string, default: nil
  slot :badges
  slot :meta
  slot :actions

  def list_row(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-wrap items-center gap-x-3 gap-y-1.5 border-b border-border py-3 first:pt-0 last:border-0 last:pb-0"
    >
      <div class="flex min-w-0 flex-1 basis-48 flex-col gap-0.5">
        <div class="flex flex-wrap items-center gap-2">
          <.link
            :if={@navigate}
            navigate={@navigate}
            class="truncate text-[13.5px] font-semibold text-text hover:text-accent"
          >
            {@title}
          </.link>
          <span :if={!@navigate} class="truncate text-[13.5px] font-semibold text-text">
            {@title}
          </span>
          {render_slot(@badges)}
        </div>
        <span :if={@subtitle} class="truncate text-[12px] text-text3">{@subtitle}</span>
      </div>
      <div :if={@meta != []} class="flex items-center gap-3 text-[12px] text-text3">
        {render_slot(@meta)}
      </div>
      <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc """
  A dialog patched over the page it belongs to. Closing navigates back to
  `return_to`, so the URL always reflects what is on screen.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :return_to, :string, required: true
  attr :width, :string, default: "max-w-lg"
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/45 p-4 pt-[8vh]">
      <.link patch={@return_to} class="absolute inset-0" aria-label="Close">
        <span class="sr-only">Close</span>
      </.link>
      <div
        id={@id}
        class={["relative w-full rounded-2xl border border-border bg-surface p-6 shadow-2xl", @width]}
      >
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-[15px] font-bold text-text">{@title}</h2>
          <.link
            patch={@return_to}
            class="inline-flex size-[26px] items-center justify-center rounded-lg text-text3 hover:bg-surface2 hover:text-text2"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </.link>
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Delete, or an inert button explaining why it is blocked. A `reason` makes
  it unclickable — the guard itself lives in the context.
  """
  attr :id, :string, required: true
  attr :value, :any, required: true
  attr :label, :string, default: "Delete"
  attr :confirm, :string, default: "This can't be undone. Continue?"
  attr :reason, :string, default: nil

  def delete_button(assigns) do
    ~H"""
    <.button :if={@reason} id={@id} type="button" disabled title={@reason}>
      {@label}
    </.button>
    <.button
      :if={!@reason}
      id={@id}
      variant="danger"
      type="button"
      phx-click="delete"
      phx-value-id={@value}
      data-confirm={@confirm}
    >
      {@label}
    </.button>
    """
  end

  @doc """
  A stored secret. Only ever renders whether one is set, never its value.
  """
  attr :set?, :boolean, required: true
  attr :missing_label, :string, default: "Not set"

  def secret_value(assigns) do
    ~H"""
    <span :if={@set?} class="font-mono text-[12px] tracking-widest text-text3">••••••••</span>
    <.badge :if={!@set?} variant={:warn}>{@missing_label}</.badge>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :stat, :string, required: true
  attr :detail, :string, default: nil
  attr :muted, :boolean, default: false
  slot :inner_block

  defp tile_body(assigns) do
    ~H"""
    <div class="flex items-center gap-2.5">
      <span class={[
        "flex size-8 shrink-0 items-center justify-center rounded-[10px]",
        if(@muted, do: "bg-surface2 text-text3", else: "bg-accent-soft text-accent")
      ]}>
        <.icon name={@icon} class="size-4" />
      </span>
      <span class={[
        "text-[13.5px] font-semibold",
        if(@muted, do: "text-text3", else: "text-text")
      ]}>
        {@label}
      </span>
      <span class="ml-auto">{render_slot(@inner_block)}</span>
    </div>
    <div class="flex flex-col gap-0.5">
      <span class={[
        "text-[15px] font-semibold",
        if(@muted, do: "text-text3", else: "text-text")
      ]}>
        {@stat}
      </span>
      <span :if={@detail} class="truncate text-[12px] text-text3">{@detail}</span>
    </div>
    """
  end
end
