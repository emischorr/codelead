defmodule FrontSeat.PreviewGatewayHelpers do
  @moduledoc """
  Switches the test process's instance to the subdomain preview gateway
  and restores the previous configuration on exit. App env is global, so
  every test using this must be `async: false`.
  """

  alias FrontSeat.PreviewGateway.SubdomainProxy

  @keys [:preview_gateway, :preview_domain, :preview_url]

  @doc "Activate SubdomainProxy for the duration of the test."
  @spec subdomain_gateway!(keyword()) :: :ok
  def subdomain_gateway!(opts \\ []) do
    domain = Keyword.get(opts, :domain, "preview.example.com")
    url = Keyword.get(opts, :url, scheme: "http", port: 80)

    previous = for key <- @keys, do: {key, Application.fetch_env(:front_seat, key)}

    Application.put_env(:front_seat, :preview_gateway, SubdomainProxy)
    Application.put_env(:front_seat, :preview_domain, domain)
    Application.put_env(:front_seat, :preview_url, url)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:front_seat, key, value)
        {key, :error} -> Application.delete_env(:front_seat, key)
      end)
    end)

    :ok
  end
end
