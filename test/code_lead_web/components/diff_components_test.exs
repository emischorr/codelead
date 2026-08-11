defmodule CodeLeadWeb.DiffComponentsTest do
  use ExUnit.Case, async: true

  alias CodeLeadWeb.DiffComponents

  describe "file_dom_id/1" do
    test "distinguishes paths a slug would collapse" do
      refute DiffComponents.file_dom_id("a/b.ex") == DiffComponents.file_dom_id("a-b.ex")
    end

    test "is stable for the same path" do
      assert DiffComponents.file_dom_id("lib/foo.ex") == DiffComponents.file_dom_id("lib/foo.ex")
    end

    test "yields an id safe to put in HTML and query back" do
      for path <- ["lib/foo.ex", "a b/ünïcode.md", "deep/nested/path with spaces.txt"] do
        assert DiffComponents.file_dom_id(path) =~ ~r/\A[A-Za-z0-9_-]+\z/
      end
    end
  end
end
