defmodule CodeLeadWeb.Markdown do
  @moduledoc """
  Renders agent prose, which is markdown far more often than not, to
  sanitized HTML. The only place MDEx is called — agent output is
  untrusted (a file body echoed back can carry a `<script>`), so
  sanitization is not optional and must not be configurable per
  call site.
  """

  # `unsafe: false` drops raw HTML at render; `:sanitize` cleans what the
  # markdown itself can produce. Both, because they cover different holes.
  @options [
    extension: [strikethrough: true, table: true, autolink: true, tasklist: true],
    render: [unsafe: false],
    sanitize: MDEx.Document.default_sanitize_options()
  ]

  @doc """
  Markdown to safe HTML, falling back to the escaped source when the
  document can't be rendered — a malformed message must still show up.
  """
  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(text) when text in [nil, ""], do: {:safe, ""}

  def to_html(text) when is_binary(text) do
    case MDEx.to_html(text, @options) do
      {:ok, html} -> {:safe, html}
      {:error, _reason} -> fallback(text)
    end
  end

  defp fallback(text) do
    {:safe, escaped} = Phoenix.HTML.html_escape(text)
    {:safe, ["<p>", escaped, "</p>"]}
  end
end
