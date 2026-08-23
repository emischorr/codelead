defmodule CodeLeadWeb.DashboardLive.SessionsTest do
  # async: false — preview and terminal sessions register in app-global
  # registries by task id, and these tiles count what is in them.
  use CodeLeadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Preview
  alias CodeLead.Terminal

  setup :register_and_log_in_user

  # Sessions started through `ensure_session/2` elsewhere in the suite
  # live under the app-global supervisor, not the test one, so they
  # outlive the test that made them. These tiles count exactly what is
  # in the registries, so start from a clean slate rather than asserting
  # deltas against whatever ran before.
  setup do
    Enum.each(Preview.active_task_ids(), &Preview.stop/1)
    Enum.each(Terminal.active_task_ids(), &Terminal.stop/1)
    :ok
  end

  defp sh, do: System.find_executable("sh")

  defp long_running_opener do
    fn ->
      Port.open({:spawn_executable, sh()}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: ["-c", "sleep 30"]
      ])
    end
  end

  # Started directly rather than through `ensure_session/2`: the tiles
  # count sessions, and this needs no repository, worktree, preview
  # command or container to make one.
  defp start_preview!(task_id) do
    start_supervised!(
      {Preview.Session,
       %{
         task_id: task_id,
         port_opener: long_running_opener(),
         stopper: fn _os_pid -> :ok end,
         probe: fn -> :waiting end
       }},
      id: {:preview, task_id}
    )
  end

  defp start_terminal!(task_id) do
    start_supervised!(
      {Terminal.Session,
       %{
         task_id: task_id,
         pty?: false,
         port_opener: long_running_opener(),
         stopper: fn _os_pid -> :ok end,
         resizer: fn _cols, _rows -> :ok end
       }},
      id: {:terminal, task_id}
    )
  end

  defp stop!(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
  end

  defp tile_value(view, id) do
    view
    |> element("#" <> id)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".font-mono")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp tile(view, id), do: view |> element("#" <> id) |> render()

  describe "with nothing running" do
    test "both tiles read zero and say so", %{conn: conn} do
      project_fixture()

      {:ok, view, _html} = live(conn, ~p"/")

      assert tile_value(view, "tile-previews") == "0"
      assert tile_value(view, "tile-terminals") == "0"
      assert tile(view, "tile-previews") =~ "None running"
      assert tile(view, "tile-terminals") =~ "None open"
    end
  end

  describe "counting" do
    test "a live preview counts and names its task", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Add search"})
      start_preview!(task.id)

      {:ok, view, _html} = live(conn, ~p"/")

      assert tile_value(view, "tile-previews") == "1"
      assert tile(view, "tile-previews") =~ "##{task.id} Add search"
    end

    test "the two tiles count independently", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Fix login"})
      start_terminal!(task.id)

      {:ok, view, _html} = live(conn, ~p"/")

      assert tile_value(view, "tile-terminals") == "1"
      assert tile(view, "tile-terminals") =~ "##{task.id} Fix login"
      assert tile_value(view, "tile-previews") == "0"
    end

    test "a session whose task is gone degrades to the bare id", %{conn: conn} do
      project_fixture()
      orphan_id = System.unique_integer([:positive])
      start_preview!(orphan_id)

      {:ok, view, _html} = live(conn, ~p"/")

      assert tile_value(view, "tile-previews") == "1"
      assert tile(view, "tile-previews") =~ "##{orphan_id}"
    end

    test "every session gets its own row, none summarized away", %{conn: conn} do
      project = project_fixture()
      first = task_fixture(project.id, %{title: "Alpha"})
      second = task_fixture(project.id, %{title: "Beta"})
      third = task_fixture(project.id, %{title: "Gamma"})

      Enum.each([first, second, third], &start_preview!(&1.id))

      {:ok, view, _html} = live(conn, ~p"/")

      assert tile_value(view, "tile-previews") == "3"

      for task <- [first, second, third] do
        assert has_element?(view, "#session-row-preview-#{task.id}")
        assert has_element?(view, "#close-preview-session-#{task.id}")
      end
    end
  end

  describe "closing a session" do
    test "the button stops a terminal and drops its row", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Fix login"})
      pid = start_terminal!(task.id)

      {:ok, view, _html} = live(conn, ~p"/")
      assert tile_value(view, "tile-terminals") == "1"

      ref = Process.monitor(pid)
      view |> element("#close-terminal-session-#{task.id}") |> render_click()
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

      assert tile_value(view, "tile-terminals") == "0"
      refute has_element?(view, "#session-row-terminal-#{task.id}")
    end

    test "the button stops a preview and drops its row", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Add search"})
      pid = start_preview!(task.id)

      {:ok, view, _html} = live(conn, ~p"/")
      assert tile_value(view, "tile-previews") == "1"

      ref = Process.monitor(pid)
      view |> element("#close-preview-session-#{task.id}") |> render_click()
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

      assert tile_value(view, "tile-previews") == "0"
      refute has_element?(view, "#session-row-preview-#{task.id}")
    end

    test "a row left by a session that died silently clears on click", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)
      pid = start_preview!(task.id)

      {:ok, view, _html} = live(conn, ~p"/")

      # A brutal kill runs no `terminate/2`, so nothing is announced and
      # the row survives its session. `stop/1` then finds nothing to do:
      # only the local delete clears it before the next periodic tick.
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
      assert has_element?(view, "#close-preview-session-#{task.id}")

      view |> element("#close-preview-session-#{task.id}") |> render_click()

      assert tile_value(view, "tile-previews") == "0"
      assert tile(view, "tile-previews") =~ "None running"
    end
  end

  describe "live updates" do
    test "an open after mount lands without any refresh", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Add search"})

      {:ok, view, _html} = live(conn, ~p"/")
      assert tile_value(view, "tile-previews") == "0"

      start_preview!(task.id)

      # No :refresh, no :periodic — the broadcast is the whole mechanism.
      assert tile_value(view, "tile-previews") == "1"
      assert tile(view, "tile-previews") =~ "##{task.id} Add search"
    end

    test "a close after mount lands without any refresh", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Add search"})
      pid = start_terminal!(task.id)

      {:ok, view, _html} = live(conn, ~p"/")
      assert tile_value(view, "tile-terminals") == "1"

      stop!(pid)

      # The close must be applied as a delete. A session broadcasting
      # from `terminate/2` is still registered, so any "simplification"
      # that recounts the registry here reads 1 and this fails.
      assert tile_value(view, "tile-terminals") == "0"
      assert tile(view, "tile-terminals") =~ "None open"
    end

    test "the periodic tick reconciles a session that died silently", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)
      pid = start_preview!(task.id)

      {:ok, view, _html} = live(conn, ~p"/")
      assert tile_value(view, "tile-previews") == "1"

      # A brutal kill runs no `terminate/2`, so nothing is announced.
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

      send(view.pid, :periodic)
      assert tile_value(view, "tile-previews") == "0"
    end
  end
end
