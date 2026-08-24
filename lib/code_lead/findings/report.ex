defmodule CodeLead.Findings.Report do
  @moduledoc """
  Parses an advisory run's report into structured findings.

  The output contract is a text convention, not a provider feature: a
  markdown narrative followed by exactly one fenced ```json block (a
  bare trailing JSON object is accepted as a fallback). Parsing is
  deliberately lenient — an advisory run must never fail because the
  model got the tail wrong, so invalid items are dropped rather than
  rejecting the report, and an unparseable report yields `:error` with
  no side effects.

  Phase-agnostic: surveys use it today, reviews can in a later
  iteration.
  """

  alias CodeLead.Findings.Finding

  @fence ~r/^```json[ \t]*$\n(.*?)^```[ \t]*$/ims

  @severities %{"high" => :high, "medium" => :medium, "low" => :low}
  @prior_statuses %{
    "still_open" => :open,
    "resolved" => :resolved,
    "not_applicable" => :not_applicable
  }

  @doc """
  Splits a report into its JSON payload and the surrounding narrative.
  Takes the *last* fenced json block; the narrative is the report with
  that block removed.
  """
  @spec extract(String.t() | nil) :: {:ok, map(), String.t()} | :error
  def extract(content) when is_binary(content) do
    case last_fenced_block(content) do
      {json, narrative} -> decode(json, narrative)
      nil -> bare_trailing_object(content)
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

  defp last_fenced_block(content) do
    case Regex.scan(@fence, content, return: :index) do
      [] ->
        nil

      matches ->
        [[{block_start, block_len}, {json_start, json_len}]] = Enum.take(matches, -1)
        json = binary_part(content, json_start, json_len)

        narrative =
          binary_part(content, 0, block_start) <>
            binary_part(
              content,
              block_start + block_len,
              byte_size(content) - block_start - block_len
            )

        {json, String.trim(narrative)}
    end
  end

  defp decode(json, narrative) do
    case Jason.decode(json) do
      {:ok, payload} when is_map(payload) -> {:ok, payload, narrative}
      _invalid -> :error
    end
  end

  # Fallback for a model that skipped the fence: a JSON object opening
  # at the start of a line and running to the end of the report.
  defp bare_trailing_object(content) do
    trimmed = String.trim_trailing(content)

    ~r/^\{/m
    |> Regex.scan(trimmed, return: :index)
    |> Enum.reverse()
    |> Enum.find_value(:error, fn [{start, _len}] ->
      json = binary_part(trimmed, start, byte_size(trimmed) - start)

      case decode(json, String.trim(binary_part(trimmed, 0, start))) do
        {:ok, _payload, _narrative} = ok -> ok
        :error -> nil
      end
    end)
  end
end
