defmodule Mem0Web.PageController do
  use Mem0Web, :controller

  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    redirect(conn, to: ~p"/projects")
  end
end
