defmodule CodeLeadWeb.PreviewProxy.ErrorPages do
  @moduledoc """
  Self-contained branded pages the preview proxy serves instead of raw
  Bandit errors. Previews open in their own browser tab, so these pages
  carry their own inline styling — app.css is not available on proxied
  responses.
  """

  @doc """
  Nothing answered at the dialed upstream address; auto-retries.

  `diagnostics` is the readout `CodeLeadWeb.PreviewProxy.Diagnostics`
  collected — the dialed address, the relay hop behind it, the declared
  command and port, and the injected `PREVIEW_*` env. Everything the
  page needs to narrow a preview that is up on paper arrives already
  stringified; nothing here looks anything up.
  """
  @spec not_running(
          %{host: String.t(), port: :inet.port_number()} | nil,
          CodeLeadWeb.PreviewProxy.Diagnostics.t() | %{}
        ) :: String.t()
  def not_running(upstream, diagnostics \\ %{}) do
    target =
      case upstream do
        %{host: host, port: port} -> "at #{host}:#{port}"
        nil -> "on the preview port"
      end

    page(
      "Nothing is listening #{target}",
      """
      <p>
      Start your dev server from the task's Review tab
      (<strong>Start preview</strong>) or its <strong>Terminal</strong>
      tab. For container tasks it must listen on <code>0.0.0.0</code>,
      and it should honor <code>PREVIEW_BASE_PATH</code> so assets
      resolve under the preview URL. Container tasks are dialed via a
      relay sidecar's published host port — if the address above looks
      unreachable from the app, check <code>PREVIEW_PUBLISH_IP</code> /
      <code>PREVIEW_UPSTREAM_HOST</code>. This tab retries automatically.
      </p>
      #{hint_html(diagnostics[:hint])}
      #{facts_html(diagnostics[:facts])}
      #{env_html(diagnostics[:env])}
      """,
      ~s(<meta http-equiv="refresh" content="4">),
      "wide"
    )
  end

  defp hint_html(nil), do: ""
  defp hint_html(hint), do: ~s(<p class="hint">#{esc(hint)}</p>)

  defp facts_html(facts) when is_list(facts) and facts != [] do
    items =
      Enum.map_join(facts, fn {label, value} ->
        "<li>#{esc(label)} <code>#{esc(value)}</code></li>"
      end)

    "<ul>#{items}</ul>"
  end

  defp facts_html(_none), do: ""

  defp env_html(env) when is_list(env) and env != [] do
    lines = Enum.map_join(env, "\n", fn {key, value} -> esc("#{key}=#{value}") end)
    "<pre>#{lines}</pre>"
  end

  defp env_html(_none), do: ""

  # Operator-authored (the preview command) and project-configured (the
  # env) strings both land in this markup.
  defp esc(value), do: value |> to_string() |> Plug.HTML.html_escape()

  @doc "The task's repository declares no preview port."
  @spec no_port() :: String.t()
  def no_port do
    page(
      "No preview port declared",
      """
      <p>
      Declare a preview port on the task's repository
      (Settings → Projects → repository) to enable the live preview.
      </p>
      """
    )
  end

  @doc "No such task."
  @spec not_found() :: String.t()
  def not_found do
    page("Task not found", "<p>This preview URL does not match any task.</p>")
  end

  @doc """
  No authenticated session. `retry?` marks the case where the 401 came
  from a stale cookie the response itself just evicted — that one heals
  on the next request, so it reloads; a genuinely expired session must
  not, or it loops.
  """
  @spec unauthorized(boolean()) :: String.t()
  def unauthorized(retry? \\ false)

  def unauthorized(true) do
    page(
      "Restoring your session",
      ~s(<p>A stale preview cookie was cleared. This tab reloads itself.</p>),
      ~s(<meta http-equiv="refresh" content="1">)
    )
  end

  def unauthorized(false) do
    page(
      "Session expired",
      ~s(<p>Log in to CodeLead in its own tab, then reload this one.</p>)
    )
  end

  @doc """
  A preview subdomain was visited without a session or a valid launch
  token. Deliberately no auto-refresh — reloading cannot fix it; only a
  fresh Open-preview click can.
  """
  @spec handshake_required() :: String.t()
  def handshake_required do
    page(
      "Open this preview from CodeLead",
      """
      This preview must be opened from CodeLead — go to the task's
      <strong>Review</strong> tab and click <strong>Open preview</strong>.
      (Preview links carry a short-lived token; this visit had none, or
      an expired one.)
      """
    )
  end

  @doc """
  A `/preview/…` path URL was visited while the instance serves
  previews on per-task subdomains — a stale bookmark. Points at the
  launch route, which redirects onto the right origin.
  """
  @spec wrong_gateway(integer() | String.t()) :: String.t()
  def wrong_gateway(task_id) do
    page(
      "This instance uses subdomain previews",
      """
      <p>
      Previews are served on per-task subdomains here, not under
      <code>/preview/…</code> paths — this looks like a stale link.
      <a href="/preview/launch/#{task_id}">Open this task's preview</a>
      at its current address.
      </p>
      """
    )
  end

  @doc """
  The subdomain gateway 404'd a request still carrying the path
  gateway's `/preview/<id>/` mount — the signature of a dev server
  that captured `PREVIEW_BASE_PATH` before the instance switched
  gateways. `prefix` is the mount the request arrived under.
  """
  @spec stale_base_path(String.t()) :: String.t()
  def stale_base_path(prefix) do
    page(
      "This preview server predates the gateway switch",
      """
      <p>
      This request arrived under <code>#{Plug.HTML.html_escape(prefix)}</code>,
      which is where the <strong>path</strong> gateway used to mount previews.
      Previews are served at the root of their own origin here, so the dev
      server behind this page is still building URLs from the
      <code>PREVIEW_BASE_PATH</code> it captured when it started — which is
      why its stylesheets and scripts 404.
      </p>
      <p>
      <strong>Stop and start the preview</strong> from the task's Review tab.
      The new server gets an empty <code>PREVIEW_BASE_PATH</code> and serves
      at the root. A server started by hand from the Terminal tab has to be
      killed there first — CodeLead only signals the one it started.
      </p>
      <p>
      If the previewed app genuinely serves a
      <code>#{Plug.HTML.html_escape(prefix)}</code> route and this really is
      a missing page, that is the other reading of this 404.
      </p>
      """,
      "",
      "wide"
    )
  end

  @doc """
  The path gateway saw one preview page reload itself over and over —
  the signature of a previewed app emitting root-absolute URLs that
  escape the `/preview/<id>` mount. `retry_href` bypasses the breaker
  once. Deliberately no auto-refresh: reloading *is* the symptom.
  """
  @spec reload_loop(integer() | String.t(), String.t()) :: String.t()
  def reload_loop(task_id, retry_href) do
    page(
      "This preview kept reloading itself",
      """
      <p>
      The app behind this preview is emitting <strong>root-absolute</strong>
      URLs that escape <code>/preview/#{task_id}</code>. They arrive at
      CodeLead instead of your dev server; CodeLead answers them, the app's
      client gives up, and the page reloads — over and over.
      </p>
      <p>
      Setting <code>PREVIEW_BASE_PATH</code> fixes routes and static paths,
      but cannot reach these three:
      </p>
      <ul>
        <li>
          <code>new LiveSocket("/live", …)</code> in <code>assets/js/app.js</code>
          — <strong>this one is the loop.</strong> It opens against CodeLead's
          own LiveView endpoint, the channel join fails, and LiveView falls
          back to a full page load.
        </li>
        <li><code>url("/fonts/…")</code> and friends inside your CSS.</li>
        <li>Hand-written literal <code>href="/"</code> / <code>src="/…"</code> in templates.</li>
      </ul>
      <pre>#{fix_snippet()}</pre>
      <p>
      The full recipe is in <code>docs/configuration.md</code>, under
      <em>Preview base path</em>. For an app that cannot be path-prefix-hosted
      at all, <code>PREVIEW_DOMAIN</code> gives every task a real origin and
      none of this applies.
      </p>
      <p><a href="#{Plug.HTML.html_escape(retry_href)}">Load it anyway</a> — pauses this check for a few minutes.</p>
      """,
      "",
      "wide"
    )
  end

  # Angle brackets are escaped by hand: this lands inside a <pre>, and a
  # literal <meta> would be parsed as markup rather than shown.
  defp fix_snippet do
    """
    # root.html.heex — render the mount-aware socket path
    &lt;meta name="live-socket-path" content={MyAppWeb.Endpoint.path("/live")} /&gt;

    # assets/js/app.js — read it instead of hardcoding "/live"
    const path = document
      .querySelector("meta[name='live-socket-path']")
      .getAttribute("content")
    const liveSocket = new LiveSocket(path, Socket, { … })

    # assets/css/app.css — relative to the built stylesheet, so any mount
    # works (count levels from where the bundle lands, not the source)
    url("../../fonts/archivo-variable.woff2")
    """
  end

  defp page(title, body_html, extra_head \\ "", main_class \\ "") do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      #{extra_head}
      <title>#{title} · CodeLead</title>
      <style>
        body { margin: 0; min-height: 100vh; display: grid; place-items: center;
               background: #0d1117; color: #c9d1d9;
               font: 14px/1.6 ui-sans-serif, system-ui, sans-serif; }
        main { max-width: 26rem; padding: 2rem; text-align: center; }
        .mark { font-weight: 700; letter-spacing: 0.02em; color: #8b949e;
                font-size: 12px; text-transform: uppercase; }
        h1 { font-size: 17px; margin: 0.75rem 0 0.5rem; color: #e6edf3; }
        p { margin: 0; color: #8b949e; }
        code { font-family: ui-monospace, monospace; font-size: 12px;
               background: #161b22; border-radius: 4px; padding: 0.1rem 0.35rem; }
        strong { color: #c9d1d9; }
        a { color: #58a6ff; }
        p + p, p + ul, p + pre, ul + p, pre + p { margin-top: 0.85rem; }
        .hint { color: #d29922; }
        main.wide { max-width: 34rem; }
        ul { text-align: left; margin: 0.75rem 0; padding-left: 1.1rem; }
        li { margin: 0.35rem 0; color: #8b949e; }
        pre { text-align: left; background: #161b22; border-radius: 6px;
              padding: 0.7rem 0.85rem; overflow-x: auto; color: #c9d1d9;
              font: 12px/1.6 ui-monospace, monospace; }
      </style>
    </head>
    <body>
      <main class="#{main_class}">
        <div class="mark">CodeLead Preview</div>
        <h1>#{title}</h1>
        #{body_html}
      </main>
    </body>
    </html>
    """
  end
end
