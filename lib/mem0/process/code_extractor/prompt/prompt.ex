defmodule Bighead.CodeExtractor.Prompt do
  @moduledoc """
  Renders a batch of diffs — for each the file it touches, how the change
  came about and the diff text — into the user prompt of the code extractor.
  """

  require EEx

  @template Path.join(__DIR__, "prompt.eex")
  @external_resource @template

  @system_prompt """
    You extract durable code guidelines from how a developer treats code that a
    coding agent wrote.

    The input is the changes recorded to a project's files during one working
    session, grouped by file in the order they happened. Each change is a git
    diff with a `change:` line saying how it came about:

    - `agent`: the agent's own work on the developer's code. Context for reading
      the changes that follow it, never a source of guidelines by itself.
    - `requested`: the agent changed its own earlier work because the developer
      asked for it. The removed lines are what the developer rejected. The added
      lines carry their intent but the agent's habits, so read the guideline
      from what was removed and why, not from the style of what replaced it.
    - `manual`: the developer edited the agent's code by hand. Removed lines are
      the agent's, added lines are the developer's.
    - `own`: the developer edited code the agent had not touched. Both sides
      are the developer's, so it shows a habit rather than a verdict on the
      agent; it supports a guideline only when the same habit shows more than
      once.

    The signal is what the developer changed, or asked to change, after seeing
    the agent's version: what the agent got wrong, or could have done better.
    The same correction across several files is one guideline, better founded.

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
    - anything true only of this function or this project: one call that needs
      a longer timeout, one branch that needs a special case, how one of this
      project's own features should behave
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
    - Write for any project. Name no module, file, feature, or domain term of
      this project; put the guideline in terms of the language, its standard
      library, and general practice, so that it reads as sound advice in a
      different codebase in the same language. If it cannot be stated without
      this project's vocabulary, it is project knowledge, not a guideline:
      skip it.
    - Most changes hold no guideline. An empty list is the right answer far more
      often than not.
  """

  @doc """
  Renders the user prompt: for each diff its file name, how the change came
  about, and the diff text, in the order given. A diff stored before origins
  were recorded renders as `unknown`.

      Prompt.render(diffs: diffs)
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
