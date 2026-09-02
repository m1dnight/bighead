defmodule Mem0Web.DiffJSON do
  @moduledoc """
  Renders `Mem0Web.DiffController` responses.
  """

  alias Mem0.Store.Diff

  @doc """
  Renders one stored diff.
  """
  @spec create(%{diff: Diff.t()}) :: map()
  def create(%{diff: diff}) do
    %{id: diff.id, file: diff.file, scope_id: diff.scope_id}
  end

  @doc """
  Renders the reply for a payload that is not the expected shape.
  """
  @spec error(map()) :: map()
  def error(_assigns) do
    %{
      error:
        ~s(expected {"file": <path>, "diff": <diff text>, "project": <cwd>, "session": <session id>})
    }
  end
end
