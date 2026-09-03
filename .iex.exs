Logger.configure(level: :info)
# run_claude = fn ->
#   Path.wildcard(".transcripts/claude/*.jsonl")
#   |> Enum.map(fn path ->
#     content = File.read!(path)

#     case Bighead.Importer.import_transcript(content, Bighead.Ingester.Claude) do
#       {:ok, _messages} ->
#         :ok

#       err ->
#         IO.puts(inspect(err, pretty: true, limit: 1000))
#     end
#   end)
# end

# run_codex = fn ->
#   Path.wildcard(".transcripts/codex/*.jsonl")
#   |> Enum.map(fn path ->
#     content = File.read!(path)

#     case Bighead.Importer.import_transcript(content, Bighead.Ingester.Codex) do
#       {:ok, _messages} ->
#         :ok

#       err ->
#         IO.puts(inspect(err, pretty: true, limit: 1000))
#     end
#   end)
# end

# run = fn ->
#   run_claude.()
#   run_codex.()
# end

# max_scope =
#   Bighead.Store.Messages.list()
#   |> Enum.group_by(& &1.scope_id)
#   |> Enum.max_by(fn {scope_id, msgs} -> Enum.count(msgs) end)
#   |> elem(0)
#   |> Bighead.Store.Scopes.get!()
