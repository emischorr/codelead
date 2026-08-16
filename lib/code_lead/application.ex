defmodule CodeLead.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Before any child can read a licensed limit. Never raises — an
    # unusable key resolves to the community tier.
    CodeLead.License.load()

    children =
      [
        CodeLeadWeb.Telemetry,
        CodeLead.Repo,
        CodeLead.Vault,
        {Task.Supervisor, name: CodeLead.TaskSupervisor},
        {Oban, Application.fetch_env!(:code_lead, Oban)},
        {DNSCluster, query: Application.get_env(:code_lead, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: CodeLead.PubSub},
        CodeLead.Agents.SubscriptionUsageCache,
        # Before the run supervisor: TaskRunner preflights (and the
        # Bootstrap task below) call into it.
        CodeLead.Executor.HarnessStaging
      ] ++
        CodeLead.Runtime.RunSupervisor.child_specs() ++
        CodeLead.Terminal.child_specs() ++
        [
          # One-shot, async: stages the container harness onto the
          # workspace volume and reaps orphaned task containers. Never
          # crashes boot; no-ops without docker.
          Supervisor.child_spec(
            {Task, &CodeLead.Executor.DockerContainer.Bootstrap.run/0},
            id: CodeLead.Executor.DockerContainer.Bootstrap,
            restart: :temporary
          ),
          # Start to serve requests, typically the last entry
          CodeLeadWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CodeLead.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CodeLeadWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
