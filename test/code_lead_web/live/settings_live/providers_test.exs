defmodule CodeLeadWeb.SettingsLive.ProvidersTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AgentsFixtures

  alias CodeLead.Agents

  setup :register_and_log_in_user

  describe "list" do
    # The credential decrypts on load, so the page must reduce it to a
    # "set / not set" flag before it can reach the rendered output.
    test "never renders a stored credential", %{conn: conn} do
      provider_fixture(%{config: %{"api_key" => "sk-super-secret"}})

      {:ok, view, _html} = live(conn, ~p"/settings/providers")

      refute render(view) =~ "sk-super-secret"
      assert render(view) =~ "••••••••"
    end

    test "an ollama endpoint is shown in the clear", %{conn: conn} do
      provider_fixture(%{kind: :ollama, config: %{"endpoint" => "http://localhost:11434"}})

      {:ok, view, _html} = live(conn, ~p"/settings/providers")

      assert render(view) =~ "http://localhost:11434"
    end
  end

  describe "create" do
    test "stores the credential under the kind's key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      view
      |> form("#provider-form",
        provider: %{name: "Anthropic", kind: "anthropic_api", credential: "sk-new"}
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/providers")
      assert Agents.get_provider_by_name("Anthropic").config == %{"api_key" => "sk-new"}
    end

    # Browsers ignore `autocomplete="off"` on password fields and fill them from
    # saved credentials, using the preceding text input as the username. Only
    # `new-password` suppresses that. The symptom is client-side, so this pins
    # the rendered attributes rather than reproducing the autofill itself.
    test "the new form opens blank and opts out of autofill", %{conn: conn} do
      provider_fixture(%{name: "Anthropic", config: %{"api_key" => "sk-super-secret"}})

      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      assert has_element?(view, "#provider_name[value='']")
      assert has_element?(view, "#provider_name[autocomplete=off]")
      assert has_element?(view, "#provider_credential[value='']")
      assert has_element?(view, "#provider_credential[autocomplete='new-password']")
    end

    test "a blank credential keeps the form open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      view
      |> form("#provider-form",
        provider: %{name: "Anthropic", kind: "anthropic_api", credential: ""}
      )
      |> render_submit()

      assert has_element?(view, "#provider-form")
      assert render(view) =~ "can&#39;t be blank"
    end
  end

  describe "edit" do
    test "a blank credential keeps the stored one", %{conn: conn} do
      provider = provider_fixture(%{config: %{"api_key" => "sk-super-secret"}})

      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}/edit")

      view
      |> form("#provider-form",
        provider: %{name: "Renamed", kind: "anthropic_api", credential: ""}
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/providers")

      reloaded = Agents.get_provider!(provider.id)
      assert reloaded.name == "Renamed"
      assert reloaded.config == %{"api_key" => "sk-super-secret"}
    end
  end

  describe "delete" do
    test "is blocked while an agent uses the provider", %{conn: conn} do
      provider = provider_fixture()
      agent_fixture(%{provider_id: provider.id})

      {:ok, view, _html} = live(conn, ~p"/settings/providers")

      assert has_element?(view, "#delete-provider-#{provider.id}[disabled]")
    end

    test "removes an unused provider", %{conn: conn} do
      provider = provider_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings/providers")

      view |> element("#delete-provider-#{provider.id}") |> render_click()

      refute has_element?(view, "#provider-row-#{provider.id}")
    end
  end
end
