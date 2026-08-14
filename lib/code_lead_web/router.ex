defmodule CodeLeadWeb.Router do
  use CodeLeadWeb, :router

  import CodeLeadWeb.SetupGate
  import CodeLeadWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CodeLeadWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The instance is unusable until the first-run wizard has been completed.
  pipeline :setup_done do
    plug :require_setup
  end

  pipeline :setup_pending do
    plug :redirect_if_setup_done
  end

  ## First-run wizard
  #
  # Its own `live_session` so that finishing the wizard forces a full page
  # load into the app — the setup gate must be re-evaluated by the router.

  scope "/", CodeLeadWeb do
    pipe_through [:browser, :setup_pending]

    live_session :setup, on_mount: [{CodeLeadWeb.SetupGate, :redirect_if_setup_done}] do
      live "/setup", SetupLive, :index
    end

    post "/setup/admin", SetupController, :create_admin
  end

  ## Authentication
  #
  # Unauthenticated but set-up-only: before the wizard runs there are no users
  # to log in as, so these redirect to /setup too.

  scope "/", CodeLeadWeb do
    pipe_through [:browser, :setup_done]

    live_session :current_user,
      on_mount: [
        {CodeLeadWeb.SetupGate, :require_setup},
        {CodeLeadWeb.UserAuth, :mount_current_scope}
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

  scope "/", CodeLeadWeb do
    pipe_through [:browser, :setup_done, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [
        {CodeLeadWeb.SetupGate, :require_setup},
        {CodeLeadWeb.UserAuth, :require_authenticated},
        {CodeLeadWeb.NavContext, :default}
      ] do
      live "/", DashboardLive, :index

      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/email", UserLive.Settings.Email, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings.Email, :confirm_email
      live "/users/settings/password", UserLive.Settings.Password, :edit

      live "/settings", SettingsLive, :index

      live "/settings/users", SettingsLive.Users, :index
      live "/settings/users/new", SettingsLive.Users, :new
      live "/settings/users/:id/edit", SettingsLive.Users, :edit

      live "/settings/providers", SettingsLive.Providers, :index
      live "/settings/providers/new", SettingsLive.Providers, :new
      live "/settings/providers/:id/edit", SettingsLive.Providers, :edit

      live "/settings/agents", SettingsLive.Agents, :index
      live "/settings/agents/new", SettingsLive.Agents, :new
      live "/settings/agents/:id/edit", SettingsLive.Agents, :edit

      # `/new` before `/:id`, or the literal would be swallowed by the param.
      live "/settings/projects", SettingsLive.Projects, :index
      live "/settings/projects/new", SettingsLive.Projects, :new
      live "/settings/projects/:id", SettingsLive.Project, :show
      live "/settings/projects/:id/repositories/new", SettingsLive.Project, :new_repository

      live "/settings/projects/:id/repositories/:repository_id/edit",
           SettingsLive.Project,
           :edit_repository

      live "/settings/projects/:id/env/new", SettingsLive.Project, :new_env
      live "/settings/projects/:id/env/:key/edit", SettingsLive.Project, :edit_env

      live "/projects/:project_id/board", BoardLive, :index
      live "/projects/:project_id/board/new", BoardLive, :new
      live "/projects/:project_id/tasks/:id", TaskLive, :show
    end

    post "/users/update-password", UserSessionController, :update_password

    # A download is a controller response, not a LiveView render, so it
    # sits outside the `live_session` — same pipeline, same gates.
    get "/projects/:project_id/tasks/:id/artifact", TaskArtifactController, :download
  end

  # Other scopes may use custom stacks.
  # scope "/api", CodeLeadWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:code_lead, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CodeLeadWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
