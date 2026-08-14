defmodule CodeLead.Agents.SubscriptionUsageCache do
  @moduledoc """
  Polls every `:anthropic_subscription` provider's rate-limit windows on a
  timer and holds the latest reading in memory, keyed by provider id.

  `CodeLead.Agents.SubscriptionUsage` is best-effort by design — Anthropic
  publishes no API for this — so a provider whose last poll failed simply
  keeps no entry here; `current/1` then reports nothing for it rather than
  a stale or broken number.
  """

  use GenServer

  alias CodeLead.Agents
  alias CodeLead.Agents.SubscriptionUsage

  @refresh_interval :timer.minutes(3)

  @type snapshot :: %{
          provider_name: String.t(),
          five_hour: SubscriptionUsage.window() | nil,
          seven_day: SubscriptionUsage.window() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, [], name: name)
  end

  @doc """
  The latest reading for the first configured `:anthropic_subscription`
  provider, or `nil` if none is configured or nothing has been read yet.
  Never raises — a transient `:noproc` (e.g. mid supervisor restart) is
  swallowed, since this is called on every page navigation app-wide.
  """
  @spec current(GenServer.server()) :: snapshot() | nil
  def current(server \\ __MODULE__) do
    GenServer.call(server, :current)
  catch
    :exit, _ -> nil
  end

  @doc """
  Fetches every subscription provider synchronously, for tests. Does not
  reschedule the periodic timer.
  """
  @spec refresh_now(GenServer.server()) :: :ok
  def refresh_now(server \\ __MODULE__), do: GenServer.call(server, :refresh_now)

  @impl true
  def init([]) do
    if auto_refresh?(), do: send(self(), :refresh)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, snapshot(state), state}
  end

  def handle_call(:refresh_now, _from, state) do
    {:reply, :ok, do_refresh(state)}
  end

  @impl true
  def handle_info(:refresh, state) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, do_refresh(state)}
  end

  defp auto_refresh?, do: Application.get_env(:code_lead, __MODULE__, [])[:auto_refresh] != false

  defp do_refresh(state) do
    Agents.list_providers()
    |> Enum.filter(&(&1.kind == :anthropic_subscription))
    |> Enum.reduce(state, fn provider, acc ->
      case SubscriptionUsage.fetch(provider.config["oauth_token"]) do
        {:ok, usage} -> Map.put(acc, provider.id, %{name: provider.name, usage: usage})
        :error -> acc
      end
    end)
  end

  defp snapshot(state) do
    case Enum.find(Agents.list_providers(), &(&1.kind == :anthropic_subscription)) do
      nil -> nil
      provider -> state |> Map.get(provider.id) |> to_snapshot()
    end
  end

  defp to_snapshot(nil), do: nil

  defp to_snapshot(%{name: name, usage: usage}), do: Map.put(usage, :provider_name, name)
end
