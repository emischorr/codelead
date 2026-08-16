defmodule CodeLeadWeb.PreviewProxy.ErrorPages do
  @moduledoc """
  Self-contained branded pages the preview proxy serves instead of raw
  Bandit errors. Rendered inside the Review tab's iframe (or a direct
  browser tab), so they carry their own inline styling — app.css is
  not available on proxied responses.
  """

  @doc "Nothing is listening on the declared preview port; auto-retries."
  @spec not_running(:inet.port_number() | nil) :: String.t()
  def not_running(port) do
    port_label = if port, do: "port #{port}", else: "the preview port"

    page(
      "Nothing is listening on #{port_label}",
      """
      Start your dev server in the task's <strong>Terminal</strong> tab.
      For container tasks it must listen on <code>0.0.0.0</code>, and it
      should honor <code>PREVIEW_BASE_PATH</code> so assets resolve under
      the preview URL. This page retries automatically.
      """,
      ~s(<meta http-equiv="refresh" content="4">)
    )
  end

  @doc "The task's repository declares no preview port."
  @spec no_port() :: String.t()
  def no_port do
    page(
      "No preview port declared",
      """
      Declare a preview port on the task's repository
      (Settings → Projects → repository) to enable the live preview.
      """
    )
  end

  @doc "No such task."
  @spec not_found() :: String.t()
  def not_found do
    page("Task not found", "This preview URL does not match any task.")
  end

  @doc "No authenticated session."
  @spec unauthorized() :: String.t()
  def unauthorized do
    page(
      "Session expired",
      ~s(Log in to CodeLead again, then reload this preview.)
    )
  end

  defp page(title, body_html, extra_head \\ "") do
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
      </style>
    </head>
    <body>
      <main>
        <div class="mark">CodeLead Preview</div>
        <h1>#{title}</h1>
        <p>#{body_html}</p>
      </main>
    </body>
    </html>
    """
  end
end
