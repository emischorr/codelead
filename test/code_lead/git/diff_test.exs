defmodule CodeLead.Git.DiffTest do
  use ExUnit.Case, async: true

  alias CodeLead.Git.Diff
  alias CodeLead.Git.DiffFile

  @modified """
  diff --git a/lib/cleanup.ex b/lib/cleanup.ex
  index 1234567..89abcde 100644
  --- a/lib/cleanup.ex
  +++ b/lib/cleanup.ex
  @@ -42,4 +42,5 @@ defmodule Cleanup do
     @registry Registry
  -  def release(worktree) do
  +  def release(%Worktree{} = worktree) do
  +    :ok = unregister(worktree)
     end
  """

  @added """
  diff --git a/test/new_test.exs b/test/new_test.exs
  new file mode 100644
  index 0000000..1111111
  --- /dev/null
  +++ b/test/new_test.exs
  @@ -0,0 +1,2 @@
  +defmodule NewTest do
  +end
  """

  @deleted """
  diff --git a/old.txt b/old.txt
  deleted file mode 100644
  index 2222222..0000000
  --- a/old.txt
  +++ /dev/null
  @@ -1,1 +0,0 @@
  -gone
  """

  @renamed """
  diff --git a/lib/before.ex b/lib/after.ex
  similarity index 100%
  rename from lib/before.ex
  rename to lib/after.ex
  """

  @binary """
  diff --git a/logo.png b/logo.png
  index 3333333..4444444 100644
  Binary files a/logo.png and b/logo.png differ
  """

  @no_newline """
  diff --git a/a.txt b/a.txt
  index 5555555..6666666 100644
  --- a/a.txt
  +++ b/a.txt
  @@ -1,1 +1,1 @@
  -old
  \\ No newline at end of file
  +new
  \\ No newline at end of file
  """

  test "parses a modified file with line numbers" do
    assert [file] = Diff.parse(@modified)
    assert %DiffFile{status: :modified, additions: 2, deletions: 1} = file
    assert DiffFile.path(file) == "lib/cleanup.ex"

    assert [hunk] = file.hunks
    assert hunk.old_start == 42
    assert hunk.new_start == 42

    assert [ctx1, del, add1, add2, ctx2] = hunk.lines
    assert %{type: :ctx, old_no: 42, new_no: 42} = ctx1
    assert %{type: :del, old_no: 43, new_no: nil, text: "  def release(worktree) do"} = del
    assert %{type: :add, old_no: nil, new_no: 43} = add1
    assert %{type: :add, old_no: nil, new_no: 44} = add2
    assert %{type: :ctx, old_no: 44, new_no: 45, text: "  end"} = ctx2
  end

  test "parses added and deleted files" do
    assert [added] = Diff.parse(@added)
    assert %DiffFile{status: :added, old_path: nil, additions: 2, deletions: 0} = added
    assert DiffFile.path(added) == "test/new_test.exs"

    assert [deleted] = Diff.parse(@deleted)
    assert %DiffFile{status: :deleted, new_path: nil, additions: 0, deletions: 1} = deleted
    assert DiffFile.path(deleted) == "old.txt"
  end

  test "parses renames and binary files without hunks" do
    assert [renamed] = Diff.parse(@renamed)

    assert %DiffFile{status: :renamed, old_path: "lib/before.ex", new_path: "lib/after.ex"} =
             renamed

    assert renamed.hunks == []

    assert [binary] = Diff.parse(@binary)
    assert %DiffFile{binary?: true, hunks: []} = binary
    assert DiffFile.path(binary) == "logo.png"
  end

  test "skips no-newline markers without breaking counters" do
    assert [file] = Diff.parse(@no_newline)
    assert [hunk] = file.hunks
    assert [%{type: :del, old_no: 1}, %{type: :add, new_no: 1}] = hunk.lines
  end

  test "parses multiple files and computes stats" do
    files = Diff.parse(@modified <> @added <> @deleted)
    assert length(files) == 3
    assert Diff.stats(files) == %{files: 3, additions: 4, deletions: 2}
  end

  test "empty diff parses to no files" do
    assert Diff.parse("") == []
    assert Diff.stats([]) == %{files: 0, additions: 0, deletions: 0}
  end
end
