defmodule Mem0.CodeExtractor.Prompt do
  @moduledoc """
  Renders one diff — the file it touches and the diff text — into the user
  prompt of the code extractor.
  """

  require EEx

  @template Path.join(__DIR__, "prompt.eex")
  @external_resource @template

  @system_prompt """
    You extract durable code guidelines from a developer's edits to code that a
    coding agent wrote.

    The input is a git diff. Removed lines are what the agent produced. Added
    lines are what the developer replaced it with. The signal is the gap between
    them: what the agent got wrong, or could have done better.

    Extract a guideline only if it would change how the agent writes code in the
    next file, on the next task:

    - a construct swapped for an equivalent one — a stdlib call for a hand-rolled
      loop, an existing helper for duplicated code
    - naming, ordering, file layout
    - error handling added, removed, or reshaped
    - indirection the agent introduced and the developer flattened — or the
      reverse
    - a third-party API swapped for the codebase's own wrapper
    - comments or docstrings deleted as noise, or added where they were missing
    - tests rewritten — what they assert, how they set up
    - code deleted outright: defensive scaffolding, unused parameters, config
      knobs nobody asked for

    Do not extract:

    - new behavior. A feature added, a requirement that changed, a bug in the
      developer's own spec — none of these are a verdict on the agent.
    - mechanical churn: formatter output, a rename applied everywhere, reordered
      imports, whitespace
    - the content of the change — a business rule, a constant, a URL, user-facing
      copy
    - anything true only of this function: one call that needs a longer timeout,
      one branch that needs a special case
    - a restatement of what the diff did

    Rules:

    - Write each guideline as an instruction to whoever writes the code next.
      Imperative, self-contained, correct to read with no diff around it.
    - Name the rejected alternative alongside the preferred one. A guideline that
      says only what to do has thrown away the correction.
    - Pitch it at the level of generality the edit actually supports. One edit is
      one data point; do not promote it into a law.
    - Do not guess at motive. If an edit has several plausible readings, skip it.
    - If the agent's version would have been acceptable and the edit is taste at
      the margin, skip it.
    - Write each guideline in the language the developer's code and comments use.
    - Most diffs hold no guideline. An empty list is the right answer far more
      often than not.
  """

  @doc """
  Renders the user prompt: the file name followed by the diff text.

      Prompt.render(file: diff.file, diff: diff.diff)
  """
  @spec render(keyword() | map()) :: String.t()
  def render(assigns) do
    assigns
    |> Map.new()
    |> render_template()
  end

  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  EEx.function_from_file(:defp, :render_template, @template, [:assigns])
end
