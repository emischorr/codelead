defmodule CodeLead.GitHelpers do
  @moduledoc """
  Builds throwaway git repositories (bare origin + seeded default
  branch) for executor/git tests.
  """

  @identity ["-c", "user.name=Test", "-c", "user.email=test@localhost"]

  @doc """
  Creates a bare origin with one commit on `main` and returns its
  `file://` URL. Everything lives under a unique tmp path inside the
  test workspace root.
  """
  def create_origin! do
    root = Application.fetch_env!(:code_lead, :workspace_root)
    id = System.unique_integer([:positive])
    origin_path = Path.join([root, "test_origins", "origin-#{id}.git"])
    seed_path = Path.join([root, "test_origins", "seed-#{id}"])

    File.mkdir_p!(origin_path)
    {_, 0} = git(["init", "--bare", "--initial-branch=main", origin_path])

    File.mkdir_p!(seed_path)
    {_, 0} = git(["init", "--initial-branch=main", seed_path])
    File.write!(Path.join(seed_path, "README.md"), "# Seed\n")
    {_, 0} = git(["-C", seed_path, "add", "-A"])
    {_, 0} = git(["-C", seed_path | @identity] ++ ["commit", "-m", "initial"])
    {_, 0} = git(["-C", seed_path, "push", "file://#{origin_path}", "main:main"])

    File.rm_rf!(seed_path)
    "file://#{origin_path}"
  end

  @doc """
  Adds a commit directly on the origin's `main` (via a temp clone) —
  useful to simulate upstream movement.
  """
  def commit_on_origin!(git_url, filename, content) do
    root = Application.fetch_env!(:code_lead, :workspace_root)
    tmp = Path.join([root, "test_origins", "tmp-#{System.unique_integer([:positive])}"])
    {_, 0} = git(["clone", git_url, tmp])
    File.write!(Path.join(tmp, filename), content)
    {_, 0} = git(["-C", tmp, "add", "-A"])
    {_, 0} = git(["-C", tmp | @identity] ++ ["commit", "-m", "origin change"])
    {_, 0} = git(["-C", tmp, "push", "origin", "main"])
    File.rm_rf!(tmp)
    :ok
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)
end
