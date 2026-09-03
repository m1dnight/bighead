defmodule BigheadWeb.PageControllerTest do
  use BigheadWeb.ConnCase

  test "GET / redirects to the projects list", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/projects"
  end
end
