defmodule Mem0Web.ProjectLive.Index do
  @moduledoc """
  Lists every `(user, project)` pair and links through to its facts and guidelines.
  """
  use Mem0Web, :live_view

  alias Mem0.Store.Scopes

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Projects", projects: Scopes.projects())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>Projects</.header>

      <p :if={@projects == []} class="text-sm opacity-70">No projects yet.</p>

      <.table id="projects" rows={@projects} row_click={fn project -> JS.navigate(project_path(project)) end}>
        <:col :let={project} label="User">{project.user}</:col>
        <:col :let={project} label="Project">{project.project}</:col>
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
