# Tests tagged `:live` talk to real LLM/embedder APIs and cost money. They are
# excluded by default; run them with `mix test.live`.
ExUnit.configure(exclude: [:live])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Mem0.Repo, :manual)
