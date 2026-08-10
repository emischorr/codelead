defmodule CodeLead.ProjectsFixtures do
  @moduledoc """
  Test fixtures for the Projects context.
  """

  import CodeLead.AccountsFixtures

  alias CodeLead.Projects

  def project_fixture(attrs \\ %{}) do
    organization_fixture()

    {:ok, project} =
      attrs
      |> Enum.into(%{name: "Project #{System.unique_integer([:positive])}"})
      |> Projects.create_project()

    project
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
