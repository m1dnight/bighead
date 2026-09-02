Logger.configure(level: :info)
# run_claude = fn ->
#   Path.wildcard(".transcripts/claude/*.jsonl")
#   |> Enum.map(fn path ->
#     content = File.read!(path)

#     case Mem0.Importer.import_transcript(content, Mem0.Ingester.Claude) do
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

#     case Mem0.Importer.import_transcript(content, Mem0.Ingester.Codex) do
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
#   Mem0.Store.Messages.list()
#   |> Enum.group_by(& &1.scope_id)
#   |> Enum.max_by(fn {scope_id, msgs} -> Enum.count(msgs) end)
#   |> elem(0)
#   |> Mem0.Store.Scopes.get!()
