defmodule FrontSeatWeb.ApiAuth do
  @moduledoc """
  The `/api` gates, in the order the `:api` pipeline runs them:

    1. `require_api_setup/2` — before the first-run wizard there is
       nothing to serve; JSON `503 setup_required` instead of the browser
       gate's redirect.
    2. `require_api_license/2` — `:api_access` is a licensed feature;
       without it *every* request is `403 license_required`, whether or not
       it carries a valid token. Evaluated per request, so tokens are never
       touched by a license change and work again when the feature returns.
    3. `authenticate_api_token/2` — `Authorization: Bearer <token>` is the
       only credential. It resolves to the same `Scope` a browser session
       for that user gets (plus the token's identity, for provenance), so
       contexts and `Policy` work unchanged.

  The pipeline never fetches the session, so cookies cannot authenticate
  an API request; and nothing in the browser pipeline reads
  `Authorization`, so a token cannot authenticate a browser route
  (ADR-0017).
  """

  import Plug.Conn

  alias FrontSeat.Accounts
  alias FrontSeat.Accounts.Scope
  alias FrontSeat.License
  alias FrontSeatWeb.Api.Error

  @license_message "API access requires a FrontSeat license that includes the api_access feature."

  @doc "Plug: refuses every request until the instance is set up."
  @spec require_api_setup(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_api_setup(conn, _opts) do
    if Accounts.setup_done?() do
      conn
    else
      Error.send_error(conn, 503, :setup_required, "This FrontSeat instance is not set up yet.")
    end
  end

  @doc "Plug: refuses every request unless `:api_access` is licensed."
  @spec require_api_license(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_api_license(conn, _opts) do
    if License.feature_enabled?(:api_access) do
      conn
    else
      Error.send_error(conn, 403, :license_required, @license_message)
    end
  end

  @doc """
  Plug: authenticates the bearer token and assigns `:current_scope`.
  Missing, malformed, unknown (revoked) and expired tokens are all the
  same 401 — the response never says which.
  """
  @spec authenticate_api_token(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def authenticate_api_token(conn, _opts) do
    with {:ok, plaintext} <- bearer_token(conn),
         {:ok, user, token} <- Accounts.fetch_api_token(plaintext) do
      :ok = Accounts.touch_api_token(token)

      scope =
        user
        |> Scope.for_user()
        |> Scope.put_api_token(token.id, token.name)

      assign(conn, :current_scope, scope)
    else
      _ ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="FrontSeat"))
        |> Error.send_error(401, :unauthorized, "Missing, invalid or expired API token.")
    end
  end

  @doc "The message an unlicensed instance answers with, for docs and tests."
  @spec license_message() :: String.t()
  def license_message, do: @license_message

  defp bearer_token(conn) do
    with [header | _] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme),
         token when token != "" <- String.trim(token) do
      {:ok, token}
    else
      _ -> :error
    end
  end
end
