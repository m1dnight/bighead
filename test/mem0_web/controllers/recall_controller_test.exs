defmodule Mem0Web.RecallControllerTest do
  use Mem0Web.ConnCase, async: true

  alias Mem0.Embedder
  alias Mem0.Store.Facts
  alias Mem0.Store.Scopes

  setup do
    Embedder.Stub.start!()
    {:ok, scope} = Scopes.create(%{user: "u", project: "/code/widget", session: "session-1"})
    %{scope: scope}
  end

  describe "POST /recall" do
    test "replies with the relevant facts, most relevant first", %{conn: conn, scope: scope} do
      {:ok, fact} = embedded_fact(scope, "prefers Elixir", basis(0))
      {:ok, _far} = embedded_fact(scope, "orthogonal", basis(1))

      Embedder.Stub.set({:ok, [basis(0)]})

      conn = post(conn, ~p"/v1/recall", %{"prompt" => "which language?"})

      assert %{"facts" => [%{"id" => id, "fact" => "prefers Elixir"}]} = json_response(conn, 200)
      assert id == fact.id
    end

    test "a prompt nothing resembles gets an empty list", %{conn: conn} do
      Embedder.Stub.set({:ok, [basis(0)]})

      conn = post(conn, ~p"/v1/recall", %{"prompt" => "anything"})

      assert %{"facts" => []} = json_response(conn, 200)
    end

    test "a missing, blank or non-binary prompt is refused", %{conn: conn} do
      assert %{"error" => _} = conn |> post(~p"/v1/recall", %{}) |> json_response(422)

      assert %{"error" => _} =
               conn |> post(~p"/v1/recall", %{"prompt" => ""}) |> json_response(422)

      assert %{"error" => _} =
               conn |> post(~p"/v1/recall", %{"prompt" => 42}) |> json_response(422)
    end

    test "an embedder failure is a 502", %{conn: conn} do
      Embedder.Stub.set({:error, {:transport_error, :econnrefused}})

      conn = post(conn, ~p"/v1/recall", %{"prompt" => "anything"})

      assert %{"error" => _} = json_response(conn, 502)
    end
  end

  defp embedded_fact(scope, text, embedding) do
    {:ok, fact} = Facts.create(%{fact: text, scope_id: scope.id})
    Facts.update(fact, %{embedding_768: embedding})
  end

  # The i-th standard basis vector of the embedding space.
  defp basis(i) do
    0.0 |> List.duplicate(768) |> List.replace_at(i, 1.0)
  end
end
