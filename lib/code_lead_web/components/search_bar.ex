defmodule CodeLeadWeb.Components.SearchBar do
  @moduledoc """
  Self-contained global search: type ahead over tasks (and later
  agents/repos), jump straight to a result's page. Owns all of its own
  state and events, so dropping
  `<.live_component module={__MODULE__} id="..."/>` anywhere behind the
  authenticated `live_session` is enough — no assigns, no host-side event
  wiring.
  """

  use CodeLeadWeb, :live_component

  alias CodeLead.Projects
  alias CodeLead.Tasks

  @debounce_ms 200
  @result_limit 5
  @min_query_length 3

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       query: "",
       results: [],
       total: 0,
       open?: false,
       highlighted_index: 0,
       debounce_ms: @debounce_ms
     )}
  end

  # `visible_ids` comes from the parent (nil = admin, unrestricted); the
  # label lookup only needs the projects the caller may see.
  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       projects_by_id:
         Map.new(Projects.list_projects(), &{&1.id, &1})
         |> scope_labels(assigns[:visible_ids])
     )}
  end

  defp scope_labels(map, nil), do: map
  defp scope_labels(map, ids), do: Map.take(map, ids)

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="relative"
      phx-click-away="close"
      phx-target={@myself}
      phx-hook=".SearchShortcut"
    >
      <form
        id={"#{@id}-form"}
        phx-change="search"
        phx-submit="search"
        phx-target={@myself}
        class="relative"
      >
        <.icon
          name="hero-magnifying-glass"
          class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-text3"
        />
        <input
          type="text"
          id={"#{@id}-input"}
          name="query"
          value={@query}
          autocomplete="off"
          placeholder="Search tasks… (⌘K)"
          phx-debounce={@debounce_ms}
          class="w-full rounded-lg border border-border bg-surface py-2 pl-9 pr-3 text-sm text-text placeholder:text-text3 focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/40"
        />
      </form>

      <div
        :if={@open?}
        id={"#{@id}-results"}
        class="absolute z-20 mt-1.5 w-full overflow-hidden rounded-xl border border-border bg-surface shadow-lg"
      >
        <div :if={@results == []} class="px-3 py-4 text-center text-[13px] text-text3">
          No matches for "{@query}"
        </div>

        <.link
          :for={{result, index} <- Enum.with_index(@results)}
          navigate={result_path(result)}
          id={"#{@id}-result-#{result.id}"}
          class={[
            "flex items-center gap-2.5 px-3 py-2 text-sm",
            index == @highlighted_index && "bg-surface2",
            index != @highlighted_index && "hover:bg-surface2"
          ]}
        >
          <.icon name={type_icon(:task)} class="size-4 shrink-0 text-text3" />
          <.project_dot color={project_color(@projects_by_id, result.project_id)} />
          <span class="min-w-0 flex-1 truncate text-text">{result.title}</span>
          <.state_badge state={result.state} run_state={result.run_state} />
        </.link>

        <div
          :if={@total > length(@results)}
          class="border-t border-border px-3 py-2 text-[12px] text-text3"
        >
          {@total - length(@results)} more results
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SearchShortcut">
        export default {
          mounted() {
            this.input = this.el.querySelector("input")

            // Global shortcut, so it must beat the browser's own Ctrl+K
            // (address-bar search in some browsers) — hence preventDefault.
            this.onWindowKeydown = (e) => {
              if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
                e.preventDefault()
                this.input.focus()
              }
            }
            window.addEventListener("keydown", this.onWindowKeydown)

            // Handled here, not via phx-keyup, so nav isn't delayed by the
            // query input's debounce.
            this.onInputKeydown = (e) => {
              if (["ArrowDown", "ArrowUp", "Enter", "Escape"].includes(e.key)) {
                e.preventDefault()
                this.pushEventTo(this.el, "nav", {key: e.key})
              }
            }
            this.input.addEventListener("keydown", this.onInputKeydown)
          },
          destroyed() {
            window.removeEventListener("keydown", this.onWindowKeydown)
          }
        }
      </script>
    </div>
    """
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    trimmed = String.trim(query)

    socket =
      if String.length(trimmed) < @min_query_length do
        assign(socket, query: query, results: [], total: 0, open?: false)
      else
        %{results: results, total: total} =
          Tasks.search_tasks(trimmed, @result_limit, socket.assigns.visible_ids)

        assign(socket,
          query: query,
          results: results,
          total: total,
          open?: true,
          highlighted_index: 0
        )
      end

    {:noreply, socket}
  end

  def handle_event("nav", %{"key" => "ArrowDown"}, socket),
    do: {:noreply, move_highlight(socket, 1)}

  def handle_event("nav", %{"key" => "ArrowUp"}, socket),
    do: {:noreply, move_highlight(socket, -1)}

  def handle_event("nav", %{"key" => "Escape"}, socket),
    do: {:noreply, assign(socket, open?: false)}

  def handle_event("nav", %{"key" => "Enter"}, socket) do
    case Enum.at(socket.assigns.results, socket.assigns.highlighted_index) do
      nil -> {:noreply, socket}
      result -> {:noreply, push_navigate(socket, to: result_path(result))}
    end
  end

  def handle_event("nav", %{"key" => _other}, socket), do: {:noreply, socket}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open?: false)}

  defp move_highlight(%{assigns: %{results: []}} = socket, _delta), do: socket

  defp move_highlight(%{assigns: %{results: results, highlighted_index: index}} = socket, delta) do
    next = rem(index + delta + length(results), length(results))
    assign(socket, highlighted_index: next)
  end

  defp result_path(%{project_id: project_id, id: id}), do: ~p"/projects/#{project_id}/tasks/#{id}"

  defp project_color(projects_by_id, project_id) do
    case Map.fetch(projects_by_id, project_id) do
      {:ok, project} -> project.color
      :error -> :blue
    end
  end

  defp type_icon(:task), do: "hero-clipboard-document-check"
end
