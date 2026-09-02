defmodule Mem0Web.DiffControllerTest do
  use Mem0Web.ConnCase, async: true

  alias Mem0.Store.Diffs

  @payload %{
    "file" => "lib/foo.ex",
    "diff" => """
    @@ -1,2 +1,2 @@
    -def hello, do: :world
    +def hello, do: :mem0
    """
  }

  describe "POST /diffs" do
    test "stores the diff and replies with its id", %{conn: conn} do
      conn = post(conn, ~p"/v1/diffs", @payload)

      assert %{"id" => id, "file" => "lib/foo.ex"} = json_response(conn, 200)
      assert Diffs.get!(id).diff == @payload["diff"]
    end

    test "posting the same payload twice lands on the same row", %{conn: conn} do
      %{"id" => first} = conn |> post(~p"/v1/diffs", @payload) |> json_response(200)
      %{"id" => second} = conn |> post(~p"/v1/diffs", @payload) |> json_response(200)

      assert second == first
      assert [_only_one] = Diffs.list()
    end

    test "a payload missing either key is refused", %{conn: conn} do
      assert %{"error" => _} =
               conn |> post(~p"/v1/diffs", %{"file" => "lib/foo.ex"}) |> json_response(422)

      assert %{"error" => _} =
               conn |> post(~p"/v1/diffs", %{"diff" => "text"}) |> json_response(422)
    end

    test "non-binary values are refused", %{conn: conn} do
      payload = %{"file" => 42, "diff" => ["not", "a", "string"]}

      assert %{"error" => _} = conn |> post(~p"/v1/diffs", payload) |> json_response(422)
    end

    test "blank values are refused", %{conn: conn} do
      payload = %{"file" => "", "diff" => ""}

      assert %{"error" => _} = conn |> post(~p"/v1/diffs", payload) |> json_response(422)
      assert Diffs.list() == []
    end
  end
end
