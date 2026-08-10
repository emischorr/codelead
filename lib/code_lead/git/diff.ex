defmodule CodeLead.Git.Diff do
  @moduledoc """
  Parses raw `git diff` output (unified format) into `DiffFile` /
  `DiffHunk` structs for rendering. Pure string processing — no git
  invocation here.
  """

  alias CodeLead.Git.DiffFile
  alias CodeLead.Git.DiffHunk

  @doc """
  Parses a raw unified diff into a list of files.
  """
  @spec parse(String.t()) :: [DiffFile.t()]
  def parse(raw) when is_binary(raw) do
    raw
    |> String.split("\n")
    |> split_file_sections()
    |> Enum.map(&parse_file/1)
  end

  @doc """
  Totals across parsed files.
  """
  @spec stats([DiffFile.t()]) :: %{
          files: non_neg_integer(),
          additions: non_neg_integer(),
          deletions: non_neg_integer()
        }
  def stats(files) do
    %{
      files: length(files),
      additions: Enum.sum_by(files, & &1.additions),
      deletions: Enum.sum_by(files, & &1.deletions)
    }
  end

  defp split_file_sections(lines) do
    lines
    |> Enum.chunk_while(
      [],
      fn line, acc ->
        if String.starts_with?(line, "diff --git ") and acc != [] do
          {:cont, Enum.reverse(acc), [line]}
        else
          {:cont, [line | acc]}
        end
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
    |> Enum.filter(fn section -> Enum.any?(section, &String.starts_with?(&1, "diff --git ")) end)
  end

  defp parse_file(lines) do
    {header_lines, body} = Enum.split_while(lines, &(!String.starts_with?(&1, "@@")))

    file =
      Enum.reduce(header_lines, %DiffFile{}, &apply_header/2)
      |> put_paths_from_git_line(header_lines)

    hunks = parse_hunks(body)

    additions = Enum.sum_by(hunks, fn hunk -> Enum.count(hunk.lines, &(&1.type == :add)) end)
    deletions = Enum.sum_by(hunks, fn hunk -> Enum.count(hunk.lines, &(&1.type == :del)) end)

    %{file | hunks: hunks, additions: additions, deletions: deletions}
  end

  defp apply_header("new file mode" <> _rest, file), do: %{file | status: :added}
  defp apply_header("deleted file mode" <> _rest, file), do: %{file | status: :deleted}
  defp apply_header("rename from " <> path, file), do: %{file | status: :renamed, old_path: path}
  defp apply_header("rename to " <> path, file), do: %{file | status: :renamed, new_path: path}
  defp apply_header("Binary files " <> _rest, file), do: %{file | binary?: true}
  defp apply_header("--- /dev/null" <> _rest, file), do: %{file | old_path: nil}
  defp apply_header("--- a/" <> path, file), do: %{file | old_path: path}
  defp apply_header("+++ /dev/null" <> _rest, file), do: %{file | new_path: nil}
  defp apply_header("+++ b/" <> path, file), do: %{file | new_path: path}
  defp apply_header(_line, file), do: file

  # Files without hunks (binary, mode-only, or renames without content
  # changes) never see ---/+++ lines; fall back to the diff --git line.
  defp put_paths_from_git_line(%DiffFile{old_path: nil, new_path: nil} = file, header_lines) do
    with git_line when is_binary(git_line) <-
           Enum.find(header_lines, &String.starts_with?(&1, "diff --git ")),
         [old_path, new_path] <- parse_git_line_paths(git_line) do
      %{file | old_path: old_path, new_path: new_path}
    else
      _ -> file
    end
  end

  defp put_paths_from_git_line(file, _header_lines), do: file

  defp parse_git_line_paths("diff --git " <> rest) do
    case String.split(rest, " b/", parts: 2) do
      ["a/" <> old_path, new_path] -> [old_path, new_path]
      _ -> :error
    end
  end

  defp parse_hunks(body_lines) do
    body_lines
    |> Enum.chunk_while(
      [],
      fn line, acc ->
        if String.starts_with?(line, "@@") and acc != [] do
          {:cont, Enum.reverse(acc), [line]}
        else
          {:cont, [line | acc]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.filter(fn section -> match?(["@@" <> _ | _], section) end)
    |> Enum.map(&parse_hunk/1)
  end

  defp parse_hunk([header | lines]) do
    {old_start, new_start} = parse_hunk_header(header)

    {parsed, _old, _new} =
      Enum.reduce(lines, {[], old_start, new_start}, fn line, {acc, old_no, new_no} ->
        case line do
          "+" <> text ->
            {[%{type: :add, old_no: nil, new_no: new_no, text: text} | acc], old_no, new_no + 1}

          "-" <> text ->
            {[%{type: :del, old_no: old_no, new_no: nil, text: text} | acc], old_no + 1, new_no}

          "\\" <> _no_newline_marker ->
            {acc, old_no, new_no}

          " " <> text ->
            {[%{type: :ctx, old_no: old_no, new_no: new_no, text: text} | acc], old_no + 1,
             new_no + 1}

          # git never emits bare lines inside hunks except a trailing ""
          "" ->
            {acc, old_no, new_no}
        end
      end)

    %DiffHunk{
      header: header,
      old_start: old_start,
      new_start: new_start,
      lines: Enum.reverse(parsed)
    }
  end

  defp parse_hunk_header(header) do
    case Regex.run(~r/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, header) do
      [_match, old_start, new_start] ->
        {String.to_integer(old_start), String.to_integer(new_start)}

      nil ->
        {0, 0}
    end
  end
end
