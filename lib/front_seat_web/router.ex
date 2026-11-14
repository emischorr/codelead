defmodule FrontSeatWeb.Router do
  use FrontSeatWeb, :router

  import FrontSeatWeb.ApiAuth
  import FrontSeatWeb.Authorization
  import FrontSeatWeb.SetupGate
  import FrontSeatWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FrontSeatWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  # Bearer-token only: no session, no cookies, no CSRF. Setup, then the
  # license, then the token — so an unlicensed instance refuses every
  # request the same way, valid token or not. See `FrontSeatWeb.ApiAuth`.
  pipeline :api do
    plug :accepts, ["json"]
    plug :require_api_setup
    plug :require_api_license
    plug :authenticate_api_token
  end

  # The instance is unusable until the first-run wizard has been completed.
  pipeline :setup_done do
    plug :require_setup
  end

  pipeline :setup_pending do
    plug :redirect_if_setup_done
  end

  # Authorization gates for the split app scopes below; each has a
  # matching on_mount hook in its live_session (live navigation never
  # re-runs router pipelines).
  pipeline :admin do
    plug :require_admin
  end

  pipeline :project_access do
    plug :require_project_access
  end

  # The preview proxy carries arbitrary proxied traffic, so it skips the
  # `:browser` conveniences that would mangle it — `:accepts` (asset
  # requests would 406), CSRF (proxied POSTs would be rejected), and the
  # secure browser headers (they'd stamp FrontSeat's CSP onto proxied
  # responses) — while keeping the same session auth as the app routes.
  pipeline :preview do
    plug :fetch_session
    plug :fetch_current_scope_for_user
    plug FrontSeatWeb.Plugs.RequirePreviewAccess
    plug FrontSeatWeb.Plugs.PreviewLoopGuard
  end

  ## First-run wizard
  #
  # Its own `live_session` so that finishing the wizard forces a full page
  # load into the app — the setup gate must be re-evaluated by the router.

  scope "/", FrontSeatWeb do
    pipe_through [:browser, :setup_pending]

    live_session :setup,
      on_mount: [
        {FrontSeatWeb.SetupGate, :redirect_if_setup_done},
        {FrontSeatWeb.UserAuth, :mount_current_scope}
      ] do
      live "/setup", SetupLive, :index
    end

    post "/setup/admin", SetupController, :create_admin
  end

  ## Authentication
  #
  # Unauthenticated but set-up-only: before the wizard runs there are no users
  # to log in as, so these redirect to /setup too.

  scope "/", FrontSeatWeb do
    pipe_through [:browser, :setup_done]

    live_session :current_user,
      on_mount: [
        {FrontSeatWeb.SetupGate, :require_setup},
        {FrontSeatWeb.UserAuth, :mount_current_scope}
      ] do
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  ## Application
  #
  # Everything behind both gates: the instance must be set up *and* the user
  # logged in.

  scope "/", FrontSeatWeb do
    pipe_through [:browser, :setup_done, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [
        {FrontSeatWeb.SetupGate, :require_setup},
        {FrontSeatWeb.UserAuth, :require_authenticated},
        {FrontSeatWeb.NavContext, :default}
      ] do
      live "/", DashboardLive, :index

      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/email", UserLive.Settings.Email, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings.Email, :confirm_email
      live "/users/settings/password", UserLive.Settings.Password, :edit
      live "/users/settings/tokens", UserLive.Settings.Tokens, :index
      live "/users/settings/tokens/new", UserLive.Settings.NewToken, :new

      live "/settings", SettingsLive, :index

      live "/settings/agents", SettingsLive.Agents, :index
      live "/settings/agents/new", SettingsLive.Agents, :new
      live "/settings/agents/:id/edit", SettingsLive.Agents, :edit

      live "/settings/projects", SettingsLive.Projects, :index
      live "/settings/projects/new", SettingsLive.Projects, :new
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  ## Instance administration
  #
  # Admin-only pages in their own `live_session`: crossing into or out of
  # them is a full page load, so the router's `:admin` plug and the
  # session's `:require_admin` hook are both always consulted.

  scope "/", FrontSeatWeb do
    pipe_through [:browser, :setup_done, :require_authenticated_user, :admin]

    live_session :admin,
      on_mount: [
        {FrontSeatWeb.SetupGate, :require_setup},
        {FrontSeatWeb.UserAuth, :require_authenticated},
        {FrontSeatWeb.Authorization, :require_admin},
        {FrontSeatWeb.NavContext, :default}
      ] do
      live "/settings/users", SettingsLive.Users, :index
      live "/settings/users/new", SettingsLive.Users, :new
      live "/settings/users/:id/edit", SettingsLive.Users, :edit

      live "/settings/providers", SettingsLive.Providers, :index
      live "/settings/providers/new", SettingsLive.Providers, :new
      live "/settings/providers/:id/edit", SettingsLive.Providers, :edit

      live "/settings/organization", SettingsLive.Organization, :edit
      live "/settings/organization/env/new", SettingsLive.Organization, :new_env
      live "/settings/organization/env/:key/edit", SettingsLive.Organization, :edit_env
    end
  end

  ## Project-keyed pages
  #
  # Everything here resolves a project from the URL, so the access check
  # runs before any page code: the plug for HTTP mounts, the hook for
  # live navigation. This session must hold ONLY project-keyed routes —
  # `require_project_access` reads `:project_id` or the settings routes'
  # `:id` (see `FrontSeatWeb.Authorization`).

  scope "/", FrontSeatWeb do
    pipe_through [:browser, :setup_done, :require_authenticated_user, :project_access]

    live_session :project,
      on_mount: [
        {FrontSeatWeb.SetupGate, :require_setup},
        {FrontSeatWeb.UserAuth, :require_authenticated},
        {FrontSeatWeb.Authorization, :require_project_access},
        {FrontSeatWeb.NavContext, :default}
      ] do
      live "/settings/projects/:id", SettingsLive.Project, :show
      live "/settings/projects/:id/members/new", SettingsLive.Project, :new_member
      live "/settings/projects/:id/repositories/new", SettingsLive.Project, :new_repository

      live "/settings/projects/:id/repositories/:repository_id/edit",
           SettingsLive.Project,
           :edit_repository

      live "/settings/projects/:id/env/new", SettingsLive.Project, :new_env
      live "/settings/projects/:id/env/:key/edit", SettingsLive.Project, :edit_env

      live "/projects/:project_id/board", BoardLive, :index
      live "/projects/:project_id/board/new", BoardLive, :new
      live "/projects/:project_id/archive", ArchiveLive, :index
      live "/projects/:project_id/tasks/:id", TaskLive, :show
    end

    # A download is a controller response, not a LiveView render, so it
    # sits outside the `live_session` — same pipeline, same gates.
    get "/projects/:project_id/tasks/:id/artifact", TaskArtifactController, :download
  end

  ## Preview proxy
  #
  # `/launch/:task_id` is the Open-preview target: it resolves the
  # active gateway's URL for the task (minting the subdomain auth token
  # when that gateway is active) and redirects. The catch-all takes all
  # verbs and any subpath — the previewed app's own links, forms,
  # assets, and websocket upgrades all land there. Subdomain-gateway
  # traffic never reaches this scope; it is diverted by host in
  # `FrontSeatWeb.Endpoint.call/2` before the router.

  scope "/preview", FrontSeatWeb do
    pipe_through :preview

    get "/launch/:task_id", PreviewLaunchController, :launch
    match :*, "/:task_id/*path", PreviewProxyController, :proxy
  end

  ## JSON API (ADR-0017, `docs/api.md`)
  #
  # Controllers stay thin: they call the same context functions as the
  # LiveViews with the token's `Scope`, and authorization stays in `Policy`.

  scope "/api/v1", FrontSeatWeb.Api do
    pipe_through :api

    get "/me", MeController, :show
    get "/projects", ProjectController, :index
    get "/projects/:project_id/tasks", TaskController, :index
    post "/projects/:project_id/tasks", TaskController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:front_seat, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FrontSeatWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
