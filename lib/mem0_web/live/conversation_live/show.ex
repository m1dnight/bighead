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

      <div id="messages">
        <div
          :for={message <- @messages}
          class={["chat", if(message.role == "user", do: "chat-end", else: "chat-start")]}
        >
          <div class="chat-header opacity-70">
            {message.role}
            <time class="text-xs">{Calendar.strftime(message.timestamp, "%Y-%m-%d %H:%M")}</time>
          </div>
          <div class="chat-bubble w-3/5 whitespace-pre-wrap break-words text-sm">{message.content}</div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
