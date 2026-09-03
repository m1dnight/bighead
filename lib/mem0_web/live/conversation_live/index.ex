defmodule Mem0Web.ConversationLive.Index do
  @moduledoc """
  Lists every scope that carries a session and links through to its conversation.
  """
  use Mem0Web, :live_view

  alias Mem0.Store.Scopes

  @impl true
  def mount(_params, _session, socket) do
    scopes =
      Scopes.list()
      |> Enum.filter(& &1.session)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    {:ok, assign(socket, page_title: "Conversations", scopes: scopes)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>Conversations</.header>

      <p :if={@scopes == []} class="text-sm opacity-70">No conversations yet.</p>

      <.table
        id="conversations"
        rows={@scopes}
        row_click={fn scope -> JS.navigate(~p"/conversations/#{scope.session}") end}
      >
        <:col :let={scope} label="User">{scope.user}</:col>
        <:col :let={scope} label="Project">{scope.project}</:col>
        <:col :let={scope} label="Session">{scope.session}</:col>
        <:action :let={scope}>
          <.link navigate={~p"/conversations/#{scope.session}"}>Show</.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end
end
