defmodule CodeLead.Acp.Elicitation do
  @moduledoc """
  Translation layer for ACP form elicitations (`elicitation/create`):
  JSON Schema in, a flat UI-ready field list out, and a wire content map
  back.

  This module exists so that nothing downstream — not the runner, not the
  LiveView — ever parses JSON Schema. `form_fields/1` collapses the
  protocol's variety into six field types the UI can render directly, and
  `content/2` turns a submitted form back into the `accept` payload.

  Two producers reach this code through the same method. Claude Code's
  built-in `AskUserQuestion` tool arrives as `question_<n>` (a titled
  `oneOf` enum, or an array of them when multi-select) paired with a
  `question_<n>_custom` free-text field marked via `_meta`; an MCP server
  can elicit anything at all. Parsing is therefore tolerant by design —
  an unrecognized property degrades to a text input rather than raising.

  Field order is reconstructed, not preserved: JSON objects decode to
  plain maps, so `properties` arrives unordered. Keys are sorted
  naturally (`question_2` before `question_10`, a `_custom` field
  immediately after the question it belongs to), which restores the
  intended order for `AskUserQuestion` and gives a stable — if merely
  alphabetical — order for arbitrary MCP schemas.
  """

  alias CodeLead.AgentDriver

  # Splits a key into {prefix, number, suffix} so numeric runs compare as
  # numbers. `.*?` is lazy so `question_0_custom` keeps `_custom` in the
  # suffix rather than swallowing the digit into the prefix.
  @natural_key ~r/^(.*?)(\d+)(.*)$/

  @truthy ["true", "on", true]

  @doc """
  Normalizes an elicitation's `requestedSchema` into an ordered field
  list. Anything unusable — a missing, malformed, or empty schema —
  yields `[]`, which callers treat as "nothing to ask".
  """
  @spec form_fields(map() | nil) :: [AgentDriver.question_field()]
  def form_fields(%{"properties" => properties} = schema) when is_map(properties) do
    required = schema |> Map.get("required") |> List.wrap()

    properties
    |> Enum.sort_by(fn {key, _property} -> sort_key(key) end)
    |> Enum.map(fn {key, property} -> field(key, property, key in required) end)
  end

  def form_fields(_schema), do: []

  @doc """
  Builds the `accept` content map from submitted form params.

  Walks `fields` rather than `params` — the params come from a browser
  and are untrusted — coercing each value to the type the schema asked
  for and dropping anything blank or unparseable. A non-empty "Other"
  field wins over the question it belongs to, so the recorded answer is
  unambiguous.
  """
  @spec content([AgentDriver.question_field()], map()) :: map()
  def content(fields, params) when is_map(params) do
    fields
    |> Enum.flat_map(&value(&1, Map.get(params, &1.key)))
    |> Map.new()
    |> drop_overridden(fields)
  end

  def content(_fields, _params), do: %{}

  defp field(key, property, required?) when is_map(property) do
    options = options(property)

    %{
      key: key,
      label: property["title"] || humanize(key),
      description: presence(property["description"]),
      type: type(property, options),
      required?: required?,
      custom_for: custom_for(property),
      options: options
    }
  end

  defp field(key, _property, required?) do
    %{
      key: key,
      label: humanize(key),
      description: nil,
      type: :text,
      required?: required?,
      custom_for: nil,
      options: []
    }
  end

  # A string or array only becomes a choice when it actually offers
  # options; without them it is a free-text field, as is every type we do
  # not recognize.
  defp type(%{"type" => "string"}, []), do: :text
  defp type(%{"type" => "string"}, _options), do: :select
  defp type(%{"type" => "array"}, []), do: :text
  defp type(%{"type" => "array"}, _options), do: :multi_select
  defp type(%{"type" => "number"}, _options), do: :number
  defp type(%{"type" => "integer"}, _options), do: :integer
  defp type(%{"type" => "boolean"}, _options), do: :boolean
  defp type(_property, _options), do: :text

  defp options(%{"type" => "array", "items" => items}) when is_map(items), do: option_list(items)
  defp options(%{"type" => "array"}), do: []
  defp options(property), do: option_list(property)

  # `oneOf`/`anyOf` entries carry a title and description alongside the
  # value; a bare `enum` is a plain list of values that label themselves.
  defp option_list(%{"oneOf" => entries}) when is_list(entries),
    do: Enum.flat_map(entries, &option/1)

  defp option_list(%{"anyOf" => entries}) when is_list(entries),
    do: Enum.flat_map(entries, &option/1)

  defp option_list(%{"enum" => values}) when is_list(values),
    do: Enum.flat_map(values, &enum_option/1)

  defp option_list(_schema), do: []

  defp option(%{"const" => value} = entry) when is_binary(value) do
    [%{value: value, label: entry["title"] || value, description: presence(entry["description"])}]
  end

  defp option(_entry), do: []

  defp enum_option(value) when is_binary(value),
    do: [%{value: value, label: value, description: nil}]

  defp enum_option(_value), do: []

  # The marker is deliberately read from `_meta` rather than inferred
  # from the `_custom` key suffix — it is the shape the bridges agreed on.
  defp custom_for(%{"_meta" => %{"_askUserQuestionCustomAnswer" => %{"questionId" => id}}})
       when is_binary(id),
       do: id

  defp custom_for(_property), do: nil

  defp value(%{key: key, type: :multi_select}, value) do
    case value |> List.wrap() |> Enum.filter(&(is_binary(&1) and &1 != "")) do
      [] -> []
      selected -> [{key, selected}]
    end
  end

  defp value(%{key: key, type: :boolean}, value) when not is_nil(value),
    do: [{key, value in @truthy}]

  defp value(%{key: key, type: :number}, value), do: number(key, value, &Float.parse/1)
  defp value(%{key: key, type: :integer}, value), do: number(key, value, &Integer.parse/1)

  defp value(%{key: key}, value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      trimmed -> [{key, trimmed}]
    end
  end

  defp value(_field, _value), do: []

  defp number(key, value, parser) when is_binary(value) do
    case value |> String.trim() |> parser.() do
      {parsed, _rest} -> [{key, parsed}]
      :error -> []
    end
  end

  defp number(_key, _value, _parser), do: []

  # Blanks are already gone, so a key that survived is a real answer and
  # supersedes the selection it was offered alongside.
  defp drop_overridden(values, fields) do
    Enum.reduce(fields, values, fn
      %{key: key, custom_for: target}, acc when is_binary(target) ->
        if Map.has_key?(acc, key), do: Map.delete(acc, target), else: acc

      _field, acc ->
        acc
    end)
  end

  defp sort_key(key) do
    case Regex.run(@natural_key, key) do
      [_match, prefix, digits, suffix] -> {prefix, String.to_integer(digits), suffix}
      nil -> {key, 0, ""}
    end
  end

  defp humanize(key) do
    key |> String.replace("_", " ") |> String.capitalize()
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
