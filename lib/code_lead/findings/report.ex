defmodule CodeLead.Findings.Report do
  @moduledoc """
  Parses an advisory run's report into structured findings.

  The output contract is a text convention, not a provider feature: a
  markdown narrative followed by a fenced ```json block. Parsing is
  deliberately lenient — an advisory run must never fail because the
  model got the tail wrong — so extraction runs three tiers and only
  gives up when none of them yields a report-shaped object:

    1. the last ```json marker, then a balanced-brace scan from there;
    2. every `{` in the report, outermost objects, latest first;
    3. the same candidates run through a repair pass that escapes
       stray double quotes inside string values.

  Neither the fence's position nor its closing half is required, so a
  block glued to the end of a sentence, opened with its payload on the
  same line, or left unterminated still parses.

  A candidate is only accepted when it carries a `"findings"` or
  `"prior"` key, which keeps a nested item object from being mistaken
  for the whole report when the outer object is the malformed one.

  Tier 3 is a heuristic: inside a string, a `"` closes it only when the
  next non-whitespace byte is `,`, `:`, `}` or `]`. A body carrying a
  quoted phrase immediately followed by a comma (`he said "yes", then`)
  is therefore still misread. It is a strict improvement over failing,
  not a guarantee.

  Invalid items are dropped rather than rejecting the report, and an
  unparseable report yields `:error` with no side effects.

  Phase-agnostic: surveys use it today, reviews can in a later
  iteration.
  """

  require Logger

  alias CodeLead.Findings.Finding

  @fence_marker ~r/```[ \t]*json\b/i
  @open_fence_tail ~r/```[ \t]*json\b\s*\z/i
  @close_fence_head ~r/\A\s*```[ \t]*/

  @whitespace ~c" \t\n\r"
  @string_terminators ~c",:}]"

  @severities %{"high" => :high, "medium" => :medium, "low" => :low}
  @prior_statuses %{
    "still_open" => :open,
    "resolved" => :resolved,
    "not_applicable" => :not_applicable
  }

  @doc """
  Splits a report into its JSON payload and the surrounding narrative.
  Takes the *last* report-shaped object; the narrative is the report
  with that object and its fence removed.
  """
  @spec extract(String.t() | nil) :: {:ok, map(), String.t()} | :error
  def extract(content) when is_binary(content) do
    with :error <- from_fence(content),
         :error <- from_objects(content, 0, &decode/1) do
      from_objects(content, 0, &repair_decode/1)
    end
  end

  def extract(_content), do: :error

  @doc """
  Normalizes the payload's `"findings"` list into insertable attrs.
  Items without a non-empty title are dropped; unknown severity
  defaults to `:medium`; titles are truncated to the schema limit.
  """
  @spec new_findings(map()) :: [map()]
  def new_findings(%{"findings" => items}) when is_list(items) do
    Enum.flat_map(items, &normalize_finding/1)
  end

  def new_findings(_payload), do: []

  @doc """
  Normalizes the payload's `"prior"` classifications. Entries with an
  unknown id shape or status are ignored.
  """
  @spec prior(map()) :: [%{id: integer(), observed: atom()}]
  def prior(%{"prior" => entries}) when is_list(entries) do
    Enum.flat_map(entries, &normalize_prior/1)
  end

  def prior(_payload), do: []

  defp normalize_finding(%{"title" => title} = item) when is_binary(title) do
    case String.trim(title) do
      "" ->
        []

      trimmed ->
        [
          %{
            title: String.slice(trimmed, 0, Finding.title_limit()),
            severity: Map.get(@severities, item["severity"], :medium),
            body: if(is_binary(item["body"]), do: item["body"]),
            paths: normalize_paths(item["paths"])
          }
        ]
    end
  end

  defp normalize_finding(_item), do: []

  defp normalize_paths(paths) when is_list(paths), do: Enum.filter(paths, &is_binary/1)
  defp normalize_paths(_paths), do: []

  defp normalize_prior(%{"id" => id, "status" => status}) do
    with {:ok, id} <- prior_id(id),
         {:ok, observed} <- Map.fetch(@prior_statuses, status) do
      [%{id: id, observed: observed}]
    else
      _invalid -> []
    end
  end

  defp normalize_prior(_entry), do: []

  defp prior_id(id) when is_integer(id), do: {:ok, id}

  defp prior_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _other -> :error
    end
  end

  defp prior_id(_id), do: :error

  # Tier 1: the fence marker is only a hint about where to look. Its
  # closing half is never required.
  defp from_fence(content) do
    case Regex.scan(@fence_marker, content, return: :index) do
      [] -> :error
      matches -> matches |> List.last() |> then(fn [{start, len}] -> start + len end)
    end
    |> case do
      :error -> :error
      offset -> from_objects(content, offset, &decode/1)
    end
  end

  # Outermost decodable objects at or after `min_offset`, latest first.
  # An accepted object masks the candidates nested inside it; a
  # rejected one masks nothing, so a stray `{` in the narrative cannot
  # swallow the real payload.
  defp from_objects(content, min_offset, decoder) do
    content
    |> object_starts(min_offset)
    |> Enum.reduce({[], 0}, fn start, {acc, consumed_until} = state ->
      with true <- start >= consumed_until,
           {:ok, json} <- object_at(content, start),
           {:ok, payload} <- decoder.(json),
           true <- report_payload?(payload) do
        {[{start, byte_size(json), payload} | acc], start + byte_size(json)}
      else
        _skip -> state
      end
    end)
    |> elem(0)
    |> case do
      [] -> :error
      [{start, len, payload} | _rest] -> {:ok, payload, narrative(content, start, len)}
    end
  end

  defp object_starts(content, min_offset) do
    ~r/\{/
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(fn [{start, _len}] -> if start >= min_offset, do: [start], else: [] end)
  end

  # Guards against a nested item object standing in for the whole
  # report when the outer object is the one that failed to decode.
  defp report_payload?(payload) when is_map(payload) do
    Map.has_key?(payload, "findings") or Map.has_key?(payload, "prior")
  end

  defp report_payload?(_payload), do: false

  defp narrative(content, start, len) do
    prefix = binary_part(content, 0, start)
    stop = start + len
    suffix = binary_part(content, stop, byte_size(content) - stop)

    String.trim(
      String.replace(prefix, @open_fence_tail, "") <>
        String.replace(suffix, @close_fence_head, "")
    )
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _invalid -> :error
    end
  end

  defp repair_decode(json) do
    case decode(repair_quotes(json)) do
      {:ok, payload} ->
        Logger.info("findings report: recovered after escaping stray quotes in the payload")
        {:ok, payload}

      :error ->
        :error
    end
  end

  # Byte-level scans are safe on UTF-8: `{`, `}`, `"` and `\` are all
  # ASCII and never appear as continuation bytes, so multi-byte
  # characters in report bodies pass through untouched.
  defp object_at(content, start) do
    case scan_object(content, byte_size(content), start + 1, 1, false, false) do
      {:ok, stop} -> {:ok, binary_part(content, start, stop - start)}
      :error -> :error
    end
  end

  defp scan_object(_content, size, pos, _depth, _in_string, _escaped) when pos >= size, do: :error

  defp scan_object(content, size, pos, depth, in_string, true),
    do: scan_object(content, size, pos + 1, depth, in_string, false)

  defp scan_object(content, size, pos, depth, true, false) do
    case :binary.at(content, pos) do
      ?\\ -> scan_object(content, size, pos + 1, depth, true, true)
      ?" -> scan_object(content, size, pos + 1, depth, false, false)
      _other -> scan_object(content, size, pos + 1, depth, true, false)
    end
  end

  defp scan_object(content, size, pos, depth, false, false) do
    case :binary.at(content, pos) do
      ?" -> scan_object(content, size, pos + 1, depth, true, false)
      ?{ -> scan_object(content, size, pos + 1, depth + 1, false, false)
      ?} when depth == 1 -> {:ok, pos + 1}
      ?} -> scan_object(content, size, pos + 1, depth - 1, false, false)
      _other -> scan_object(content, size, pos + 1, depth, false, false)
    end
  end

  defp repair_quotes(json) do
    json
    |> repair_scan(0, byte_size(json), false, false, [])
    |> IO.iodata_to_binary()
  end

  defp repair_scan(_json, pos, size, _in_string, _escaped, acc) when pos >= size,
    do: Enum.reverse(acc)

  defp repair_scan(json, pos, size, in_string, true, acc),
    do: repair_scan(json, pos + 1, size, in_string, false, [:binary.at(json, pos) | acc])

  defp repair_scan(json, pos, size, true, false, acc) do
    case :binary.at(json, pos) do
      ?\\ -> repair_scan(json, pos + 1, size, true, true, [?\\ | acc])
      ?" -> repair_quote(json, pos, size, acc)
      byte -> repair_scan(json, pos + 1, size, true, false, [byte | acc])
    end
  end

  defp repair_scan(json, pos, size, false, false, acc) do
    case :binary.at(json, pos) do
      ?" -> repair_scan(json, pos + 1, size, true, false, [?" | acc])
      byte -> repair_scan(json, pos + 1, size, false, false, [byte | acc])
    end
  end

  # A quote inside a string closes it only when the next non-whitespace
  # byte is one that may follow a value. Anything else is content the
  # model failed to escape.
  defp repair_quote(json, pos, size, acc) do
    if string_ends?(json, pos + 1, size) do
      repair_scan(json, pos + 1, size, false, false, [?" | acc])
    else
      repair_scan(json, pos + 1, size, true, false, ["\\\"" | acc])
    end
  end

  defp string_ends?(json, pos, size) do
    case skip_whitespace(json, pos, size) do
      :eof -> true
      byte -> byte in @string_terminators
    end
  end

  defp skip_whitespace(_json, pos, size) when pos >= size, do: :eof

  defp skip_whitespace(json, pos, size) do
    case :binary.at(json, pos) do
      byte when byte in @whitespace -> skip_whitespace(json, pos + 1, size)
      byte -> byte
    end
  end
end
