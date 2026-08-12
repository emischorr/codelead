defmodule CodeLead.Acp.ElicitationTest do
  use ExUnit.Case, async: true

  alias CodeLead.Acp.Elicitation

  # What Claude Code's ACP adapter actually sends for a two-question
  # AskUserQuestion call: a titled single-select with per-option
  # descriptions, its "Other" companion, and a multi-select.
  @ask_user_question %{
    "type" => "object",
    "properties" => %{
      "question_0" => %{
        "type" => "string",
        "title" => "Approach",
        "oneOf" => [
          %{
            "const" => "Refactor first",
            "title" => "Refactor first",
            "description" => "Clean up, then build"
          },
          %{"const" => "Ship it", "title" => "Ship it"}
        ]
      },
      "question_0_custom" => %{
        "type" => "string",
        "title" => "Other",
        "description" => "Type your own answer instead of choosing an option above (optional).",
        "_meta" => %{
          "_askUserQuestionCustomAnswer" => %{
            "questionId" => "question_0",
            "isCustomAnswer" => true
          }
        }
      },
      "question_1" => %{
        "type" => "array",
        "title" => "Areas",
        "description" => "Which areas?",
        "items" => %{
          "anyOf" => [
            %{"const" => "api", "title" => "API"},
            %{"const" => "ui", "title" => "UI"}
          ]
        }
      }
    }
  }

  describe "form_fields/1" do
    test "normalizes an AskUserQuestion schema into ordered, typed fields" do
      assert [select, custom, multi] = Elicitation.form_fields(@ask_user_question)

      assert %{key: "question_0", label: "Approach", type: :select, custom_for: nil} = select

      assert select.options == [
               %{
                 value: "Refactor first",
                 label: "Refactor first",
                 description: "Clean up, then build"
               },
               %{value: "Ship it", label: "Ship it", description: nil}
             ]

      assert %{key: "question_0_custom", label: "Other", type: :text} = custom
      assert custom.custom_for == "question_0"

      assert %{key: "question_1", label: "Areas", type: :multi_select} = multi
      assert multi.description == "Which areas?"
      assert Enum.map(multi.options, & &1.label) == ["API", "UI"]
    end

    test "sorts numbered keys naturally, keeping a custom field beside its question" do
      schema = %{
        "properties" => %{
          "question_10" => %{"type" => "string"},
          "question_2" => %{"type" => "string"},
          "question_2_custom" => %{"type" => "string"},
          "question_1" => %{"type" => "string"}
        }
      }

      assert schema |> Elicitation.form_fields() |> Enum.map(& &1.key) ==
               ["question_1", "question_2", "question_2_custom", "question_10"]
    end

    test "reads untitled enum and array-of-enum variants" do
      schema = %{
        "properties" => %{
          "a_choice" => %{"type" => "string", "enum" => ["one", "two"]},
          "b_choices" => %{"type" => "array", "items" => %{"enum" => ["x"]}}
        }
      }

      assert [choice, choices] = Elicitation.form_fields(schema)

      assert choice.type == :select

      assert choice.options == [
               %{value: "one", label: "one", description: nil},
               %{value: "two", label: "two", description: nil}
             ]

      assert choices.type == :multi_select
      assert choices.options == [%{value: "x", label: "x", description: nil}]
    end

    test "degrades a generic MCP schema to plain inputs and honours required" do
      schema = %{
        "type" => "object",
        "required" => ["name"],
        "properties" => %{
          "name" => %{"type" => "string", "title" => "Your name"},
          "count" => %{"type" => "integer"},
          "ratio" => %{"type" => "number"},
          "agree" => %{"type" => "boolean"},
          "_future" => %{"type" => "quantum"},
          "untyped" => %{}
        }
      }

      by_key = schema |> Elicitation.form_fields() |> Map.new(&{&1.key, &1})

      assert by_key["name"].type == :text
      assert by_key["name"].required?
      assert by_key["count"].type == :integer
      assert by_key["ratio"].type == :number
      assert by_key["agree"].type == :boolean
      assert by_key["_future"].type == :text
      assert by_key["untyped"].type == :text
      refute by_key["count"].required?
    end

    test "labels an untitled field from its key" do
      assert [%{label: "Retention window"}] =
               Elicitation.form_fields(%{"properties" => %{"retention_window" => %{}}})
    end

    test "a choice with no usable options is a free-text field" do
      schema = %{
        "properties" => %{"pick" => %{"type" => "string", "oneOf" => [%{"title" => "no const"}]}}
      }

      assert [%{type: :text, options: []}] = Elicitation.form_fields(schema)
    end

    test "yields nothing for a missing, empty, or malformed schema" do
      assert Elicitation.form_fields(nil) == []
      assert Elicitation.form_fields(%{}) == []
      assert Elicitation.form_fields(%{"properties" => %{}}) == []
      assert Elicitation.form_fields(%{"properties" => "nope"}) == []
      assert Elicitation.form_fields("nope") == []
    end
  end

  describe "content/2" do
    setup do
      %{fields: Elicitation.form_fields(@ask_user_question)}
    end

    test "coerces a submitted form into the wire payload", %{fields: fields} do
      assert Elicitation.content(fields, %{
               "question_0" => "Ship it",
               "question_0_custom" => "",
               "question_1" => ["api", "ui"]
             }) == %{"question_0" => "Ship it", "question_1" => ["api", "ui"]}
    end

    test "a typed Other answer supersedes its question's selection", %{fields: fields} do
      assert Elicitation.content(fields, %{
               "question_0" => "Ship it",
               "question_0_custom" => "  Do neither  "
             }) == %{"question_0_custom" => "Do neither"}
    end

    test "drops blanks, empty selections, and keys not in the schema", %{fields: fields} do
      assert Elicitation.content(fields, %{
               "question_0" => "   ",
               "question_1" => [],
               "smuggled" => "value"
             }) == %{}
    end

    test "parses numbers and booleans, dropping what will not parse" do
      fields =
        Elicitation.form_fields(%{
          "properties" => %{
            "count" => %{"type" => "integer"},
            "ratio" => %{"type" => "number"},
            "agree" => %{"type" => "boolean"},
            "broken" => %{"type" => "integer"}
          }
        })

      assert Elicitation.content(fields, %{
               "count" => "3",
               "ratio" => "1.5",
               "agree" => "true",
               "broken" => "not a number"
             }) == %{"count" => 3, "ratio" => 1.5, "agree" => true}
    end

    test "an unchecked box reads as false, an absent one as nothing" do
      fields = Elicitation.form_fields(%{"properties" => %{"agree" => %{"type" => "boolean"}}})

      assert Elicitation.content(fields, %{"agree" => "false"}) == %{"agree" => false}
      assert Elicitation.content(fields, %{}) == %{}
    end

    test "a single checkbox arrives as a bare string", %{fields: fields} do
      assert Elicitation.content(fields, %{"question_1" => "api"}) == %{"question_1" => ["api"]}
    end

    test "non-map params yield nothing", %{fields: fields} do
      assert Elicitation.content(fields, nil) == %{}
    end
  end
end
