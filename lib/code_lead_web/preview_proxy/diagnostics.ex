defmodule CodeLeadWeb.PreviewProxy.Diagnostics do
  @moduledoc """
  What the proxy can say about a preview that would not answer, reduced
  to plain strings for the error page.

  Collecting it here is what keeps `CodeLeadWeb.PreviewProxy.ErrorPages`
  free of the domains it would otherwise have to reach into, and keeps
  the lookups off the happy path — nothing here runs unless a request
  has already failed.

  Deliberately narrow: the injected `PREVIEW_*` pairs are the only env
  that appears. The project env store the same session is spawned with
  holds forge tokens and provider credentials, and must never reach a
  rendered page.
  """

  alias CodeLead.PreviewGateway
  alias CodeLead.PreviewGateway.Relay
  alias CodeLead.Projects
  alias CodeLead.Tasks.Task

  @typedoc """
  `facts` are ordered label/value pairs, already stringified; `hint`
  names a misconfiguration when one is recognisable.
  """
  @type t :: %{
          facts: [{String.t(), String.t()}],
          env: [{String.t(), String.t()}],
          hint: String.t() | nil
        }

  @doc """
  The dialed address, the relay hop behind it, the repository's preview
  command and port, and the env the server was started with.
  `app_origin` is the app's own external origin — the caller owns that
  lookup.
  """
  @spec collect(Task.t(), PreviewGateway.upstream() | nil, String.t()) :: t()
  def collect(%Task{} = task, upstream, app_origin) do
    {command, port} = declared(task)

    facts =
      [
        {"proxy dialed", dialed(upstream)},
        {"relay forwards to", relay_target(task)},
        {"preview command", command},
        {"preview port", port && Integer.to_string(port)}
      ]
      |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)

    %{facts: facts, env: PreviewGateway.preview_env(task, app_origin), hint: hint(command, port)}
  end

  defp declared(%Task{target: :repo, repository_id: id}) when is_integer(id) do
    repository = Projects.get_repository!(id)
    {repository.preview_command, repository.preview_port}
  end

  defp declared(%Task{}), do: {nil, nil}

  defp dialed(%{host: host, port: port}), do: "#{host}:#{port}"
  defp dialed(nil), do: nil

  # Only container tasks have a hop the proxy cannot see; a local task's
  # dev server is dialed straight on loopback.
  defp relay_target(%Task{execution_env: :container, id: task_id}) do
    case Relay.forward_target(task_id) do
      {:ok, endpoint} -> endpoint
      :error -> nil
    end
  end

  defp relay_target(%Task{}), do: nil

  # The failure worth naming is the one that is invisible from either
  # side: a command that binds its framework's default port while the
  # proxy dials the declared one. Both halves look healthy alone.
  defp hint(command, port) when is_binary(command) and is_integer(port) do
    mentioned? =
      String.contains?(command, "PREVIEW_PORT") or
        String.contains?(command, Integer.to_string(port))

    if mentioned? do
      nil
    else
      "The command names neither $PREVIEW_PORT nor #{port}, so the server is " <>
        "probably listening on its framework's default port rather than the one " <>
        "the preview dials."
    end
  end

  defp hint(_command, _port), do: nil
end
