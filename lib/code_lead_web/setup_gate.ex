defmodule CodeLeadWeb.SetupGate do
  @moduledoc """
  Gates the instance on the first-run wizard.

  `organizations.settings["setup_done"]` is the flag: until it is set, every
  browser request is redirected to `/setup`; once it is set, `/setup` itself
  redirects back to the root.

  Both faces are needed. The plugs cover HTTP requests and the initial
  LiveView mount; the `on_mount` hooks cover live navigation *within* a
  `live_session`, which never re-runs the router pipelines.
  """

  use CodeLeadWeb, :verified_routes

  import Phoenix.Controller, only: [redirect: 2]
  import Plug.Conn, only: [halt: 1]

  alias CodeLead.Accounts

  @doc """
  Plug: sends the user to the wizard until the instance is set up.
  """
  @spec require_setup(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_setup(conn, _opts) do
    if Accounts.setup_done?() do
      conn
    else
      conn |> redirect(to: ~p"/setup") |> halt()
    end
  end

  @doc """
  Plug: sends the user out of the wizard once the instance is set up.
  """
  @spec redirect_if_setup_done(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def redirect_if_setup_done(conn, _opts) do
    if Accounts.setup_done?() do
      conn |> redirect(to: ~p"/") |> halt()
    else
      conn
    end
  end

  @doc """
  LiveView `on_mount` counterparts of the two plugs.
  """
  def on_mount(:require_setup, _params, _session, socket) do
    if Accounts.setup_done?() do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/setup")}
    end
  end

  def on_mount(:redirect_if_setup_done, _params, _session, socket) do
    if Accounts.setup_done?() do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, socket}
    end
  end
end
