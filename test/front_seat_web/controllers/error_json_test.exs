defmodule FrontSeatWeb.ErrorJSONTest do
  use FrontSeatWeb.ConnCase, async: true

  test "renders 404 in the API error shape" do
    assert FrontSeatWeb.ErrorJSON.render("404.json", %{}) ==
             %{error: %{code: :not_found, message: "Not Found."}}
  end

  test "renders 500 in the API error shape" do
    assert FrontSeatWeb.ErrorJSON.render("500.json", %{}) ==
             %{error: %{code: :internal_error, message: "Internal Server Error."}}
  end
end
