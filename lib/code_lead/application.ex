defmodule CodeLead.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        CodeLeadWeb.Telemetry,
        CodeLead.Repo,
        CodeLead.Vault,
        {Task.Supervisor, name: CodeLead.TaskSupervisor},
        {Oban, Application.fetch_env!(:code_lead, Oban)},
        {DNSCluster, query: Application.get_env(:code_lead, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: CodeLead.PubSub}
      ] ++
        CodeLead.Runtime.RunSupervisor.child_specs() ++
        [
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
