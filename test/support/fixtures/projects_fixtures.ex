defmodule CodeLead.ProjectsFixtures do
  @moduledoc """
  Test fixtures for the Projects context.
  """

  import CodeLead.AccountsFixtures

  alias CodeLead.Projects
  alias CodeLead.Projects.Project

  @doc """
  Inserts a project directly — no creator, no membership rows, no default
  budget copy. Pair it with `membership_fixture/3` when the test needs
  project access; `Projects.create_project/2` is exercised by its own tests.
  """
  def project_fixture(attrs \\ %{}) do
    organization = organization_fixture()

    attrs = Enum.into(attrs, %{name: "Project #{System.unique_integer([:positive])}"})

    %Project{org_id: organization.id}
    |> Project.changeset(attrs)
    |> CodeLead.Repo.insert!()
  end

  @doc """
  Sets budget limits directly — in the context they are admin-only, which
  scheduler/cost tests don't care about.
  """
  def set_project_budget!(project, attrs) do
    project |> Ecto.Changeset.change(attrs) |> CodeLead.Repo.update!()
  end

  def repository_fixture(project_id, attrs \\ %{}) do
    {:ok, repository} =
      Projects.link_repository(
        project_id,
        Enum.into(attrs, %{
          name: "repo-#{System.unique_integer([:positive])}",
          git_url: "https://example.com/org/repo.git",
          default_branch: "main"
        })
      )

    repository
  end
end
