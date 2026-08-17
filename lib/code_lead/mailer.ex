defmodule CodeLead.Mailer do
  @moduledoc """
  Swoosh mailer plus the instance-wide switch that decides whether any email
  surface exists at all.

  Mail is **opt-in**: an instance that configures nothing has no transport, so
  the magic-link and invite flows are hidden rather than silently failing.
  `enabled?/0` reads a dedicated `:mail_enabled` key instead of sniffing the
  adapter, because the adapter cannot carry the answer — dev wants mail on with
  the Local adapter, and prod inherits that same adapter with no transport
  behind it.

  Like `CodeLead.License.feature_enabled?/1`, check it at the call site **and**
  in the authoritative server-side action; hiding a button is cosmetic.
  """

  use Swoosh.Mailer, otp_app: :code_lead

  # The preview route only exists in a build with the dev routes compiled in.
  @dev_routes Application.compile_env(:code_lead, :dev_routes, false)

  @doc """
  Whether this instance can send email at all.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:code_lead, :mail_enabled, false)

  @doc """
  Whether sent mail lands in a browsable local mailbox at `/dev/mailbox`.

  Both halves matter: the Local adapter stores the mail, and the dev routes
  expose the preview. A production build has the former without the latter.
  """
  @spec local_mailbox?() :: boolean()
  def local_mailbox? do
    Application.get_env(:code_lead, __MODULE__)[:adapter] == Swoosh.Adapters.Local and
      @dev_routes
  end

  @doc """
  Sender for transactional mail, as Swoosh's `{name, address}` pair.
  """
  @spec from() :: {String.t(), String.t()}
  def from do
    Application.get_env(:code_lead, :mail_from, {"CodeLead", "codelead@localhost"})
  end
end
