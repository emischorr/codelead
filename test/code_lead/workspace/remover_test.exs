defmodule CodeLead.Workspace.RemoverTest do
  # async: false — swaps the :docker_cli config.
  use ExUnit.Case, async: false

  alias CodeLead.Git
  alias CodeLead.GitHelpers
  alias CodeLead.Workspace
  alias CodeLead.Workspace.Remover

  setup do
    original = Application.get_env(:code_lead, :docker_cli)
    on_exit(fn -> Application.put_env(:code_lead, :docker_cli, original) end)
    :ok
  end

  defp without_docker do
    Application.put_env(:code_lead, :docker_cli, ["definitely-not-docker-xyz"])
  end

  defp with_fake_docker(script_body) do
    dir = Path.join(Workspace.root(), "test_remover")
    File.mkdir_p!(dir)
    script = Path.join(dir, "fake-docker-#{System.unique_integer([:positive])}.sh")
    File.write!(script, script_body)
    on_exit(fn -> File.rm(script) end)
    Application.put_env(:code_lead, :docker_cli, ["sh", script])
  end

  # A tree a plain rm_rf cannot finish: a file inside a directory the
  # test user may not write to — the shape a root-running container
  # agent leaves behind (there it is ownership; here mode bits, same
  # eacces either way).
  defp blocked_tree!(base \\ nil) do
    id = System.unique_integer([:positive])
    path = base || Path.join([Workspace.root(), "test_remover", "blocked-#{id}"])
    locked = Path.join(path, "locked")
    File.mkdir_p!(locked)
    File.write!(Path.join(locked, "file.txt"), "unremovable")
    File.chmod!(locked, 0o555)

    on_exit(fn ->
      _ = File.chmod(locked, 0o755)
      _ = File.rm_rf(path)
    end)

    {path, locked}
  end

  describe "remove_dir/1" do
    test "refuses paths outside the workspace root" do
      outside = Path.join(System.tmp_dir!(), "codelead-remover-outside")

      assert {:error, {:outside_workspace, ^outside}} = Remover.remove_dir(outside)
    end

    test "removes an ordinary tree and is :ok for a missing one" do
      path =
        Path.join([
          Workspace.root(),
          "test_remover",
          "plain-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(Path.join(path, "nested"))
      File.write!(Path.join(path, "nested/file.txt"), "bye")

      assert :ok = Remover.remove_dir(path)
      refute File.exists?(path)

      assert :ok = Remover.remove_dir(path)
    end

    test "a blocked tree without docker surfaces the leftover" do
      without_docker()
      {path, _locked} = blocked_tree!()

      assert {:error, {:leftover, ^path}} = Remover.remove_dir(path)
      assert File.exists?(path)
    end

    test "a blocked tree escalates to a root removal through docker" do
      log =
        Path.join(
          Workspace.root(),
          "test_remover/escalation-#{System.unique_integer([:positive])}.log"
        )

      System.put_env("FAKE_REMOVER_LOG", log)
      on_exit(fn -> System.delete_env("FAKE_REMOVER_LOG") end)

      # Records the argv, then clears the tree the way root would —
      # dropping the mode bits that blocked the plain rm_rf.
      with_fake_docker("""
      echo "$@" >> "$FAKE_REMOVER_LOG"
      for last do :; done
      chmod -R u+w "$last"
      rm -rf "$last"
      """)

      {path, _locked} = blocked_tree!()

      assert :ok = Remover.remove_dir(path)
      refute File.exists?(path)

      parent = Path.dirname(path)
      assert File.read!(log) =~ "run --rm -v #{parent}:#{parent} alpine:3.20 rm -rf #{path}"
    end

    test "an escalation that changes nothing reports root-owned leftovers" do
      with_fake_docker("exit 0\n")
      {path, _locked} = blocked_tree!()

      assert {:error, {:leftover_root_files, ^path}} = Remover.remove_dir(path)
      assert File.exists?(path)
    end

    # Real docker: a container writes a root-owned tree, the escalation
    # removes it. On Docker Desktop (macOS) the bind mount maps
    # ownership back to the user, so this exercises less than on a
    # Linux host — the end state assertion holds on both.
    @tag :docker
    test "removes a genuinely root-owned tree via the real daemon" do
      path =
        Path.join([
          Workspace.root(),
          "test_remover",
          "rooted-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(path)

      on_exit(fn ->
        _ =
          System.cmd("docker", [
            "run",
            "--rm",
            "-v",
            "#{path}:/t",
            "alpine:3.20",
            "rm",
            "-rf",
            "/t"
          ])
      end)

      {_out, 0} =
        System.cmd("docker", [
          "run",
          "--rm",
          "-v",
          "#{path}:/t",
          "alpine:3.20",
          "sh",
          "-c",
          "mkdir /t/rootdir && touch /t/rootdir/file && chmod 755 /t/rootdir"
        ])

      assert :ok = Remover.remove_dir(path)
      refute File.exists?(path)
    end
  end

  describe "Git.remove_worktree/2 with a blocked worktree" do
    setup do
      without_docker()

      root = Workspace.root()
      id = System.unique_integer([:positive])
      clone = Path.join([root, "test_remover", "clone-#{id}"])
      worktree = Path.join([root, "test_remover", "worktree-#{id}"])
      on_exit(fn -> Enum.each([clone, worktree], &File.rm_rf/1) end)

      {:ok, _} = Git.ensure_clone(GitHelpers.create_origin!(), clone)
      {:ok, _} = Git.create_worktree(clone, worktree, "codelead/task-#{id}", "main")

      %{clone: clone, worktree: worktree}
    end

    test "reports the leftover and keeps the repo-wide prune for later",
         %{clone: clone, worktree: worktree} do
      {_blocked, locked} = blocked_tree!(Path.join(worktree, "blocked"))

      assert {:error, {:leftover, leftover}} = Git.remove_worktree(clone, worktree)
      assert leftover == worktree
      assert File.exists?(worktree)

      # Once the blocker is gone the same call finishes and prunes.
      File.chmod!(locked, 0o755)
      assert :ok = Git.remove_worktree(clone, worktree)
      refute File.exists?(worktree)

      {:ok, list} = Git.git(clone, ["worktree", "list", "--porcelain"])
      refute list =~ worktree
    end
  end
end
