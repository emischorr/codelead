defmodule CodeLead.MailHelpers do
  @moduledoc """
  Flips the instance-wide mail switch for tests.

  The suite runs with mail enabled (see `config/test.exs`) so the invite and
  magic-link paths are exercised by the ordinary tests. A test that asserts the
  *absence* of those surfaces calls `disable_mail!/0` in its own `setup`.

  It writes application env, which is VM-global: a module calling it must be
  `async: false`.
  """

  @doc """
  Turns mail off for the rest of the test, restoring it on exit.

  Meant to be called from a `setup` block — it registers its own `on_exit`.
  """
  @spec disable_mail!() :: :ok
  def disable_mail! do
    previous = Application.get_env(:code_lead, :mail_enabled)
    Application.put_env(:code_lead, :mail_enabled, false)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:code_lead, :mail_enabled, previous) end)
    :ok
  end
end
