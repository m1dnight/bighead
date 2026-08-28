run_claude = fn ->
  Path.wildcard(".transcripts/claude/*.jsonl")
  |> Enum.map(fn path ->
    content = File.read!(path)

    case Mem0.Importer.import_transcript(content, Mem0.Ingester.Claude) do
      {:ok, _messages} ->
        :ok

      err ->
        IO.puts(inspect(err, pretty: true, limit: 1000))
    end
  end)
end


run_codex = fn ->
  Path.wildcard(".transcripts/codex/*.jsonl")
  |> Enum.map(fn path ->
    content = File.read!(path)

    case Mem0.Importer.import_transcript(content, Mem0.Ingester.Codex) do
      {:ok, _messages} ->
        :ok

      err ->
        IO.puts(inspect(err, pretty: true, limit: 1000))
    end
  end)
end
