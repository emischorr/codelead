defmodule CodeLead.Tasks.AttentionTest do
  use ExUnit.Case, async: true

  alias CodeLead.Tasks.Attention

  describe "blocks_agent?/1" do
    test "nil attention never blocks" do
      refute Attention.blocks_agent?(nil)
    end

    test "an executor-sourced question or permission request blocks" do
      assert Attention.blocks_agent?(%Attention{type: :agent_question, source: :executor})
      assert Attention.blocks_agent?(%Attention{type: :permission_request, source: :executor})
    end

    test "an advisory-sourced question or permission request does not block" do
      refute Attention.blocks_agent?(%Attention{type: :agent_question, source: :advisory})
      refute Attention.blocks_agent?(%Attention{type: :permission_request, source: :advisory})
    end

    test "run_failed and review_ready never block, regardless of source" do
      refute Attention.blocks_agent?(%Attention{type: :run_failed, source: :executor})
      refute Attention.blocks_agent?(%Attention{type: :review_ready, source: :advisory})
    end
  end
end
