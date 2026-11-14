defmodule FrontSeat.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Before any child can read a licensed limit. Never raises — an
    # unusable key resolves to the community tier.
    FrontSeat.License.load()

    # Warns (never raises) when PREVIEW_DOMAIN is not same-site with
    # PHX_HOST — that setup breaks preview cookies and is unsupported.
    FrontSeat.PreviewGateway.DomainCheck.warn_on_cross_site()

    children =
      [
        FrontSeatWeb.Telemetry,
        FrontSeat.Repo,
        FrontSeat.Vault,
        # Blocking one-shot, before anything that can dispatch a run
        # (Oban's dispatch queue included): heals persisted workspace
        # paths after a WORKSPACE_ROOT move. Never fails boot.
        FrontSeat.Workspace.Reconciler,
        {Task.Supervisor, name: FrontSeat.TaskSupervisor},
        {Oban, Application.fetch_env!(:front_seat, Oban)},
        {DNSCluster, query: Application.get_env(:front_seat, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: FrontSeat.PubSub},
        # Blocking one-shot (needs Repo and PubSub above): flags
        # finalizations a restart interrupted for human review. Never
        # retries them and never fails boot.
        FrontSeat.Runtime.FinalizeReconciler,
        FrontSeat.Agents.SubscriptionUsageCache,
        # Before the run supervisor: TaskRunner preflights (and the
        # Bootstrap task below) call into it.
        FrontSeat.Executor.HarnessStaging
      ] ++
        FrontSeat.Runtime.RunSupervisor.child_specs() ++
        FrontSeat.Terminal.child_specs() ++
        FrontSeat.Preview.child_specs() ++
        [
          # One-shot, async: re-attaches sessions to container previews
          # that outlived an ungraceful exit, so Review shows the server
          # that is actually serving instead of offering to start a
          # second one. Needs the Preview registry above it.
          Supervisor.child_spec(
            {Task, &FrontSeat.Preview.adopt_at_boot/0},
            id: FrontSeat.Preview.Adopter,
            restart: :temporary
          ),
          # One-shot, async: stages the container harness onto the
          # workspace volume and reaps orphaned task environments. Never
          # crashes boot; no-ops without docker.
          Supervisor.child_spec(
            {Task, &FrontSeat.Executor.Devcontainer.Bootstrap.run/0},
            id: FrontSeat.Executor.Devcontainer.Bootstrap,
            restart: :temporary
          ),
          # Before the endpoint: the path gateway's reload-loop breaker
          # must own its state before a request can count against it.
          FrontSeatWeb.PreviewProxy.LoopBreaker,
          # Start to serve requests, typically the last entry
          FrontSeatWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FrontSeat.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FrontSeatWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
