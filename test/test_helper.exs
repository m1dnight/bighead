# Tests tagged `:live` talk to real LLM/embedder APIs and cost money. They are
# excluded by default; run them with `mix test.live`.
ExUnit.configure(exclude: [:live])
ExUnit.start()

# `mix test.core` runs the functional core alone and starts no Repo, so there is
# no sandbox to put into manual mode — see `Mem0.Application`. Every other entry
# point gets the Repo and this line.
if Application.get_env(:mem0, :start_repo, true) do
  Ecto.Adapters.SQL.Sandbox.mode(Mem0.Repo, :manual)
end
