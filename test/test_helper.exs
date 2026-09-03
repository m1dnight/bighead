# Tests tagged `:live` talk to real LLM/embedder APIs and cost money. They are
# excluded by default; run them with `mix test.live`.
#
# `:corpus` is excluded for a different reason: those tests read the Claude Code
# transcripts in `~/.claude/projects`, so they pass or fail on what a particular
# machine happens to hold. Run them with `mix test --include corpus`.
ExUnit.configure(exclude: [:live, :corpus])
ExUnit.start()

# `mix test.core` runs the functional core alone and starts no Repo, so there is
# no sandbox to put into manual mode — see `Bighead.Application`. Every other entry
# point gets the Repo and this line.
if Application.get_env(:bighead, :start_repo, true) do
  Ecto.Adapters.SQL.Sandbox.mode(Bighead.Repo, :manual)
end
