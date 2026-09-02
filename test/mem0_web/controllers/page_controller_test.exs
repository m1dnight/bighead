defmodule Mem0Web.PageControllerTest do
  use Mem0Web.ConnCase

  test "GET / redirects to the projects list", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/projects"
  end
end
