defmodule CodeLead.Runtime.SessionTeardownTest do
  # async: false — swaps the :terminal_command config and sessions
  # register in the app-global Terminal/Preview registries.
  use CodeLead.DataCase, async: false

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Preview
  alias CodeLead.Runtime.StageEffects
  alias CodeLead.Terminal

  @fake_shell Path.expand("../../support/fake_shell.sh", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :terminal_command)
    Application.put_env(:code_lead, :terminal_command, ["/bin/sh", @fake_shell])

    worktree =
      Path.join(System.tmp_dir!(), "teardown_worktree_#{System.unique_integer([:positive])}")

    File.mkdir_p!(worktree)

    on_exit(fn ->
      if original,
        do: Application.put_env(:code_lead, :terminal_command, original),
        else: Application.delete_env(:code_lead, :terminal_command)

      File.rm_rf(worktree)
    end)

    %{worktree: worktree}
  end

  defp task_with_sessions(worktree) do
    project = project_fixture()

    repository =
      repository_fixture(project.id, %{preview_port: 5173, preview_command: "sleep 300"})

    task =
      project.id
      |> task_fixture(%{target: :repo, repository_id: repository.id})
      |> put_context!(%{worktree_path: worktree, branch_name: "codelead/teardown-test"})

    {:ok, terminal} = Terminal.ensure_session(task)
    {:ok, preview} = Preview.ensure_session(task)

    %{task: task, terminal: terminal, preview: preview}
  end

  test "discarding the context stops both sessions", %{worktree: worktree} do
    %{task: task, terminal: terminal, preview: preview} = task_with_sessions(worktree)

    terminal_ref = Process.monitor(terminal)
    preview_ref = Process.monitor(preview)

    StageEffects.discard_context(task)

    assert_receive {:DOWN, ^terminal_ref, :process, ^terminal, :normal}, 2_000
    assert_receive {:DOWN, ^preview_ref, :process, ^preview, :normal}, 2_000
    refute Terminal.alive?(task.id)
    assert Preview.status(task.id) == :stopped
  end

  test "releasing the context stops both sessions", %{worktree: worktree} do
    %{task: task, terminal: terminal, preview: preview} = task_with_sessions(worktree)

    terminal_ref = Process.monitor(terminal)
    preview_ref = Process.monitor(preview)

    StageEffects.release_context(task)

    assert_receive {:DOWN, ^terminal_ref, :process, ^terminal, :normal}, 2_000
    assert_receive {:DOWN, ^preview_ref, :process, ^preview, :normal}, 2_000
    refute Terminal.alive?(task.id)
  end

  # The decision this pins: request-changes preserves the worktree, the
  # branch and the ACP session, so it must preserve the shell the human
  # is holding too. Only the preview stops — it is the reviewed
  # artifact, and would otherwise serve a build the run is rewriting.
  test "entering a run stops the preview but keeps the terminal", %{worktree: worktree} do
    %{task: task, terminal: terminal, preview: preview} = task_with_sessions(worktree)

    preview_ref = Process.monitor(preview)
    terminal_ref = Process.monitor(terminal)

    StageEffects.on_enter(:execute, task, nil)

    assert_receive {:DOWN, ^preview_ref, :process, ^preview, :normal}, 2_000
    refute_receive {:DOWN, ^terminal_ref, :process, ^terminal, _reason}, 300
    assert Terminal.alive?(task.id)
  end
end
