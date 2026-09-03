defmodule BigheadWeb.ConversationLive.Index do
  @moduledoc """
  Lists every scope that carries a session and links through to its conversation.
  """
  use BigheadWeb, :live_view

  alias Bighead.Store.Scopes

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
    <Layouts.app flash={@flash} max_width="max-w-4xl">
      <.header>Conversations</.header>

      <p :if={@scopes == []} class="text-sm opacity-70">No conversations yet.</p>

      <.table
        id="conversations"
        rows={@scopes}
        row_click={fn scope -> JS.navigate(~p"/conversations/#{scope.session}") end}
      >
        <:col :let={scope} label="User">
          <span class="badge badge-ghost">{scope.user}</span>
        </:col>
        <:col :let={scope} label="Project">
          <span class="font-mono text-xs">{scope.project}</span>
        </:col>
        <:col :let={scope} label="Session">
          <span class="block max-w-40 truncate font-mono text-xs" title={scope.session}>
            {scope.session}
          </span>
        </:col>
        <:action :let={scope}>
          <.link navigate={~p"/conversations/#{scope.session}"}>Show</.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end
end
