defmodule CodeLead.Projects.Repository do
  @moduledoc """
  A git repository linked to a project by URL. `base_clone_path` is
  filled in once the managed base clone exists on the workspace volume.

  `env_kind`/`devcontainer_path`/`image_ref`/`dockerfile` declare the
  repository's toolchain environment for the container executor.
  `env_kind` is derived, not chosen: a non-blank `image_ref` means
  `:image`, blank means `:default` — declaring an image *enables*
  Container execution for the repo's tasks, while the choice itself
  stays per task (`tasks.execution_env`, default `:local`), so a task
  that needs no toolchain keeps running locally (ADR-0003/0004).
  `:devcontainer` and `:dockerfile` remain dormant seams, unreachable
  from the UI and untouched by the derivation.

  `preview_port` declares the port a dev server inside this repo's
  tasks listens on; declaring it enables the Review tab's live preview.
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

    field :env_kind, Ecto.Enum,
      values: [:devcontainer, :image, :dockerfile, :default],
      default: :default

    field :devcontainer_path, :string
    field :image_ref, :string
    field :dockerfile, :string
    field :preview_port, :integer

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
      :image_ref,
      :dockerfile,
      :preview_port
    ])
    |> update_change(:image_ref, &normalize_ref/1)
    |> derive_env_kind()
    |> validate_number(:preview_port, greater_than: 0, less_than: 65_536)
    |> validate_required([:name, :git_url, :default_branch])
    |> unique_constraint([:project_id, :name])
  end

  # A whitespace-only ref would slip past the executor's `ref != ""`
  # guard while naming no image. Cast maps `""` to a nil change, so nil
  # arrives here too.
  defp normalize_ref(nil), do: nil

  defp normalize_ref(ref) do
    case String.trim(ref) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Only flips between :default and :image — a dormant kind set via
  # console stays untouched. Consequence: an explicit `env_kind: :image`
  # with a blank ref derives back to :default rather than erroring.
  defp derive_env_kind(changeset) do
    case get_field(changeset, :env_kind) do
      kind when kind in [:default, :image] ->
        derived = if get_field(changeset, :image_ref), do: :image, else: :default
        put_change(changeset, :env_kind, derived)

      _dormant ->
        changeset
    end
  end
end
