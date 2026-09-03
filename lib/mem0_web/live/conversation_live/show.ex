defmodule Mem0Web.ConversationLive.Show do
  @moduledoc """
  Shows one conversation: every message captured for a single session, in order.
  """
  use Mem0Web, :live_view

  alias Mem0.Store.Messages

  @impl true
  def mount(%{"session" => session}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: session,
       session: session,
       messages: Messages.get_session(session)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Conversation
        <:subtitle>{@session}</:subtitle>
        <:actions>
          <.button navigate={~p"/conversations"}>Back to conversations</.button>
        </:actions>
      </.header>

      <p :if={@messages == []} class="text-sm opacity-70">No messages yet.</p>

      <div id="messages" class="space-y-4">
        <div :for={message <- @messages} class="rounded-lg border border-base-300 p-3">
          <div class="mb-1 flex justify-between text-xs opacity-70">
            <span class="font-semibold">{message.role}</span>
            <span>{Calendar.strftime(message.timestamp, "%Y-%m-%d %H:%M:%S")}</span>
          </div>
          <p class="whitespace-pre-wrap break-words text-sm">{message.content}</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
