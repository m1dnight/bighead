defmodule Mem0Web.TranscriptJSON do
  @moduledoc """
  Renders `Mem0Web.TranscriptController` responses.
  """

  alias Mem0.Store.Message
  alias Mem0.Store.Scope

  @doc """
  Renders a stored transcript: how many messages, and the scope they landed
  in. The scope is projected to its identifying fields — an Ecto struct is
  not JSON-encodable, and the watermark is bookkeeping, not an answer.
  """
  @spec create(%{messages: [Message.t()], session: Scope.t()}) :: map()
  def create(%{messages: messages, session: scope}) do
    %{
      stored: Enum.count(messages),
      scope: %{user: scope.user, project: scope.project, session: scope.session}
    }
  end

  @doc """
  Renders a failure with the reason the controller gives it.
  """
  @spec error(%{message: String.t()}) :: map()
  def error(%{message: message}) do
    %{error: message}
  end
end
