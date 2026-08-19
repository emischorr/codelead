defmodule CodeLead.PreviewGateway.DomainCheckTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodeLead.PreviewGateway.DomainCheck

  defp warning(preview_domain, phx_host) do
    capture_log(fn -> DomainCheck.warn_on_cross_site(preview_domain, phx_host) end)
  end

  test "silent when the preview domain shares the registrable domain" do
    assert warning("preview.example.com", "codelead.example.com") == ""
    assert warning("preview.example.com", "example.com") == ""
  end

  test "warns on a foreign registrable domain, recommending the same-site one" do
    log = warning("preview.other.net", "codelead.example.com")

    assert log =~ "PREVIEW_DOMAIN (preview.other.net)"
    assert log =~ "unsupported"
    assert log =~ "PREVIEW_DOMAIN=preview.example.com"
  end

  test "silent when the gateway is off or hosts are dev-shaped" do
    assert warning(nil, "codelead.example.com") == ""
    assert warning("preview.localhost", "localhost") == ""
    assert warning("preview.localhost", "codelead.example.com") == ""
    assert warning("preview.example.com", "127.0.0.1") == ""
  end
end
