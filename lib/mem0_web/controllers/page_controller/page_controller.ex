defmodule Mem0Web.PageController do
  use Mem0Web, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
