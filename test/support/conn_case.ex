defmodule Mem0Web.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Mem0Web.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # See the note in `Mem0.DataCase`: the setup below checks out a sandbox
      # connection, so these tests need the container too.
      use Mem0Web, :verified_routes

      import Mem0Web.ConnCase
      import Phoenix.ConnTest
      import Plug.Conn

      @moduletag :db

      # The default endpoint for testing
      @endpoint Mem0Web.Endpoint

      # Import conveniences for testing with connections
    end
  end

  setup tags do
    Mem0.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
