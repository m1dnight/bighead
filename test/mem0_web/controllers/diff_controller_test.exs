defmodule Mem0Web.DiffControllerTest do
  use Mem0Web.ConnCase, async: true

  alias Mem0.Store.Diffs
  alias Mem0.Store.Scopes

  @payload %{
    "file" => "lib/foo.ex",
    "diff" => """
    @@ -1,2 +1,2 @@
    -def hello, do: :world
    +def hello, do: :mem0
    """,
    "project" => "/code/widget",
    "session" => "session-1"
  }

  describe "POST /diffs" do
    test "stores the diff and replies with its id", %{conn: conn} do
      conn = post(conn, ~p"/v1/diffs", @payload)

      assert %{"id" => id, "file" => "lib/foo.ex", "scope_id" => scope_id} =
               json_response(conn, 200)

      assert Diffs.get!(id).diff == @payload["diff"]
      assert Diffs.get!(id).scope_id == scope_id
    end

    test "files the diff under the scope of its project and session", %{conn: conn} do
      %{"scope_id" => scope_id} = conn |> post(~p"/v1/diffs", @payload) |> json_response(200)

      assert {:ok, scope} = Scopes.get_by_session("session-1")
      assert scope.id == scope_id
      assert scope.project == "/code/widget"
    end

    test "a session already known from a transcript reuses its scope", %{conn: conn} do
      {:ok, existing} =
        Scopes.create(%{user: "default", project: "/code/widget", session: "session-1"})

      %{"scope_id" => scope_id} = conn |> post(~p"/v1/diffs", @payload) |> json_response(200)

      assert scope_id == existing.id
      assert [_only_one] = Scopes.list()
    end

    test "posting the same payload twice lands on the same row", %{conn: conn} do
      %{"id" => first} = conn |> post(~p"/v1/diffs", @payload) |> json_response(200)
      %{"id" => second} = conn |> post(~p"/v1/diffs", @payload) |> json_response(200)

      assert second == first
      assert [_only_one] = Diffs.list()
    end

    test "a payload missing any key is refused", %{conn: conn} do
      for key <- Map.keys(@payload) do
        assert %{"error" => _} =
                 conn |> post(~p"/v1/diffs", Map.delete(@payload, key)) |> json_response(422)
      end

      assert Diffs.list() == []
    end

    test "non-binary values are refused", %{conn: conn} do
      payload = %{@payload | "file" => 42, "diff" => ["not", "a", "string"]}

      assert %{"error" => _} = conn |> post(~p"/v1/diffs", payload) |> json_response(422)
    end

    test "blank values are refused", %{conn: conn} do
      for key <- Map.keys(@payload) do
        assert %{"error" => _} =
                 conn |> post(~p"/v1/diffs", %{@payload | key => "  "}) |> json_response(422)
      end

      assert Diffs.list() == []
      assert Scopes.list() == []
    end
  end
end
