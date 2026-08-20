defmodule CodeLead.Workspace.ReconcilerTest do
  use CodeLead.DataCase, async: true

  import ExUnit.CaptureLog

  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Git
  alias CodeLead.Projects
  alias CodeLead.Tasks
  alias CodeLead.Workspace
  alias CodeLead.Workspace.Reconciler

  # A root the previous deployment used — a sibling of the test
  # workspace root, so renames stay on one filesystem.
  defp old_root! do
    old_root = Path.expand("tmp/test_old_roots/old-#{System.unique_integer([:positive])}")
    File.mkdir_p!(old_root)
    on_exit(fn -> File.rm_rf(old_root) end)
    old_root
  end

  defp repo_task_rows do
    project = project_fixture()

    repository =
      repository_fixture(project.id, %{git_url: create_origin!(), default_branch: "main"})

    task =
      task_fixture(project.id, %{work_type: :code, target: :repo, repository_id: repository.id})

    %{repository: repository, task: task}
  end

  # Builds a real clone + worktree under `build_root`, records those
  # paths on the rows, then physically moves both trees to the canonical
  # locations under the current root — the state a volume migration
  # leaves behind: files present, DB rows and gitdir pointers stale.
  defp migrated_workspace!(%{repository: repository, task: task}, build_root) do
    old_clone = Path.join(build_root, "repos/clone")
    old_worktree = Path.join(build_root, "worktrees/task-#{task.id}")
    branch = "codelead/task-#{task.id}"

    {:ok, _} = Git.ensure_clone(repository.git_url, old_clone)
    {:ok, _} = Git.create_worktree(old_clone, old_worktree, branch, "main")

    {:ok, repository} = Projects.update_repository(repository, %{base_clone_path: old_clone})
    {:ok, task} = Tasks.set_execution_context(task, old_worktree, branch)

    new_clone = Workspace.base_clone_path(repository.name, repository.id)
    new_worktree = Workspace.worktree_path(task.id)
    File.mkdir_p!(Path.dirname(new_clone))
    File.mkdir_p!(Path.dirname(new_worktree))
    File.rename!(old_clone, new_clone)
    File.rename!(old_worktree, new_worktree)
    on_exit(fn -> Enum.each([new_clone, new_worktree], &File.rm_rf/1) end)

    %{repository: repository, task: task, new_clone: new_clone, new_worktree: new_worktree}
  end

  test "rewrites moved paths and repairs the worktree links" do
    %{repository: repository, task: task, new_clone: new_clone, new_worktree: new_worktree} =
      migrated_workspace!(repo_task_rows(), old_root!())

    # Broken exactly like the incident: the files moved, the pointers did not.
    assert {:error, _output} = Git.git(new_worktree, ["status"])

    assert :ok = Reconciler.run()

    assert Projects.get_repository!(repository.id).base_clone_path == new_clone
    assert Tasks.get_task!(task.id).worktree_path == new_worktree
    assert {:ok, _output} = Git.git(new_worktree, ["status"])
  end

  test "heals gitdir pointers even when the DB rows are already current" do
    rows = repo_task_rows()

    %{repository: repository, task: task, new_clone: new_clone, new_worktree: new_worktree} =
      migrated_workspace!(rows, old_root!())

    # The rows were fixed by hand (or written post-move); only git's own
    # cross-pointers are stale.
    {:ok, _} = Projects.update_repository(repository, %{base_clone_path: new_clone})
    {:ok, _} = Tasks.set_execution_context(task, new_worktree, task.branch_name)
    assert {:error, _output} = Git.git(new_worktree, ["status"])

    assert :ok = Reconciler.run()
    assert {:ok, _output} = Git.git(new_worktree, ["status"])
  end

  test "leaves genuinely lost paths untouched and says what was lost" do
    %{repository: repository, task: task} = repo_task_rows()
    {:ok, _} = Projects.update_repository(repository, %{base_clone_path: "/gone-root/repos/x"})
    {:ok, _} = Tasks.set_execution_context(task, "/gone-root/worktrees/task-#{task.id}", "b")

    log =
      capture_log(fn ->
        assert :ok = Reconciler.run()
      end)

    assert log =~ "repository #{repository.id}"
    assert log =~ "lost"
    assert log =~ "task #{task.id}"

    assert Projects.get_repository!(repository.id).base_clone_path == "/gone-root/repos/x"
    assert Tasks.get_task!(task.id).worktree_path == "/gone-root/worktrees/task-#{task.id}"
  end

  test "a second run is a no-op" do
    %{repository: repository, task: task, new_clone: new_clone, new_worktree: new_worktree} =
      migrated_workspace!(repo_task_rows(), old_root!())

    assert :ok = Reconciler.run()
    assert :ok = Reconciler.run()

    assert Projects.get_repository!(repository.id).base_clone_path == new_clone
    assert Tasks.get_task!(task.id).worktree_path == new_worktree
    assert {:ok, _output} = Git.git(new_worktree, ["status"])
  end
end
