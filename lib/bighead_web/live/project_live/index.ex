defmodule BigheadWeb.ProjectLive.Index do
  @moduledoc """
  Lists every `(user, project)` pair and links through to its facts and guidelines.
  """
  use BigheadWeb, :live_view

  alias Bighead.Store.Scopes

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Projects", projects: Scopes.projects())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} max_width="max-w-4xl">
      <.header>Projects</.header>

      <p :if={@projects == []} class="text-sm opacity-70">No projects yet.</p>

      <.table id="projects" rows={@projects} row_click={fn project -> JS.navigate(project_path(project)) end}>
        <:col :let={project} label="User">
          <span class="badge badge-ghost">{project.user}</span>
        </:col>
        <:col :let={project} label="Project">
          <span class="font-mono text-xs">{project.project}</span>
        </:col>
        <:action :let={project}>
          <.link navigate={project_path(project)}>Show</.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @spec project_path(%{user: String.t(), project: String.t() | nil}) :: String.t()
  defp project_path(%{user: user, project: project}), do: ~p"/projects/#{user}?#{[project: project]}"
end
