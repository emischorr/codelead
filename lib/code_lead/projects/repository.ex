defmodule CodeLead.Projects.Repository do
  @moduledoc """
  A git repository linked to a project by URL. `base_clone_path` is
  filled in once the managed base clone exists on the workspace volume.

  `env_kind`/`devcontainer_path` declare the repository's execution
  environment for the container executor: `:devcontainer` *enables*
  Container execution for the repo's tasks — provisioned from the
  repo's own `.devcontainer` configuration (ADR-0009) — while the
  choice itself stays per task (`tasks.execution_env`, default
  `:local`), so a task that needs no toolchain keeps running locally.
  `devcontainer_path` optionally pins the config file; blank leaves
  discovery to the devcontainer spec's search order.

  `preview_port` declares the port a dev server inside this repo's
  tasks listens on; declaring it enables the Review tab's live preview.
  `preview_command` optionally names the command that starts that
  server — declaring it enables the one-click Start preview button
  (without it the server is started by hand in the Terminal tab).

  `is_default` marks the repository a new `:repo`-target task prefills
  when the project links more than one. It is never cast through
  `changeset/2` — the first repository linked to a project is flipped on
  by `CodeLead.Projects.link_repository/2`, and it only moves after that
  through `CodeLead.Projects.set_default_repository/1`, which also
  clears it off every other repository in the project so exactly one
  stays true (enforced by a partial unique index).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "repositories" do
    field :project_id, :id
    field :name, :string
    field :git_url, :string
    field :default_branch, :string, default: "main"
    field :base_clone_path, :string
    field :is_default, :boolean, default: false

    field :env_kind, Ecto.Enum,
      values: [:devcontainer, :default],
      default: :default

    field :devcontainer_path, :string
    field :preview_port, :integer
    field :preview_command, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for linking or updating a repository. `project_id` is set
  programmatically by the context, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(repository, attrs) do
    repository
    |> cast(attrs, [
      :name,
      :git_url,
      :default_branch,
      :base_clone_path,
      :env_kind,
      :devcontainer_path,
      :preview_port,
      :preview_command
    ])
    |> update_change(:devcontainer_path, &normalize_blank/1)
    |> update_change(:preview_command, &normalize_blank/1)
    |> validate_preview_port()
    |> validate_required([:name, :git_url, :default_branch])
    |> unique_constraint([:project_id, :name])
  end

  # Preview ports are unique across the instance: local-execution
  # previews all serve from the app's own host, so two repositories on
  # one port would collide there — and the app's own port is taken by
  # CodeLead itself. Container previews would not collide (each server
  # listens inside its own container), but one rule covers both modes;
  # the assigned port reaches serve commands as PREVIEW_PORT.
  defp validate_preview_port(changeset) do
    app_port = Application.get_env(:code_lead, :app_port, 4000)

    changeset
    |> validate_number(:preview_port, greater_than: 0, less_than: 65_536)
    |> validate_exclusion(:preview_port, [app_port],
      message: "is the port this CodeLead instance itself listens on"
    )
    |> unsafe_validate_unique(:preview_port, CodeLead.Repo,
      message: "already used by another repository on this instance"
    )
    |> unique_constraint(:preview_port,
      message: "already used by another repository on this instance"
    )
  end

  # A whitespace-only value would name no config (or command) while
  # passing presence checks. Cast maps `""` to a nil change, so nil
  # arrives here too.
  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
