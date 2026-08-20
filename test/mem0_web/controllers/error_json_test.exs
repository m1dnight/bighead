defmodule Mem0Web.ErrorJSONTest do
  use Mem0Web.ConnCase, async: true

  test "renders 404" do
    assert Mem0Web.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert Mem0Web.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
