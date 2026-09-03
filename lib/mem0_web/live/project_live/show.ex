defmodule BigheadWeb.ProjectLive.Show do
  @moduledoc """
  Shows the facts and guidelines extracted for one `(user, project)` pair, across all its sessions.
  """
  use BigheadWeb, :live_view

  alias Bighead.Store.Facts

  @impl true
  def mount(%{"user" => user, "project" => project}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: project,
       user: user,
       project: project,
       facts: Facts.facts_for_project(user, project, kind: :fact),
       guidelines: Facts.facts_for_project(user, project, kind: :guideline)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@project}
        <:subtitle>{@user}</:subtitle>
        <:actions>
          <.button navigate={~p"/projects"}>Back to projects</.button>
        </:actions>
      </.header>

      <.header>Facts</.header>
      <p :if={@facts == []} class="text-sm opacity-70">No facts yet.</p>
      <ul id="facts" class="list-disc pl-5 space-y-1">
        <li :for={fact <- @facts}>{fact.fact}</li>
      </ul>

      <.header>Guidelines</.header>
      <p :if={@guidelines == []} class="text-sm opacity-70">No guidelines yet.</p>
      <ul id="guidelines" class="list-disc pl-5 space-y-1">
        <li :for={guideline <- @guidelines}>{guideline.fact}</li>
      </ul>
    </Layouts.app>
    """
  end
end
