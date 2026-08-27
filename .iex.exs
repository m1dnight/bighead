run_claude = fn ->
  Path.wildcard(".transcripts/claude/*.jsonl")
  |> Enum.map(fn path ->
    content = File.read!(path)

    case Mem0.Ingester.decode_transcript(content, Mem0.Ingester.Claude) do
      {:ok, scope, messages} ->
        {:ok, scope, messages}

      {:error, err} ->
        IO.inspect(err)
    end
  end)
end

run_codex = fn ->
  Path.wildcard(".transcripts/codex/*.jsonl")
  |> Enum.map(fn path ->
    content = File.read!(path)

    case Mem0.Ingester.decode_transcript(content, Mem0.Ingester.Codex) do
      {:ok, scope, messages} ->
        {:ok, scope, messages}

      {:error, err} ->
        IO.puts("#{path}: #{inspect(err)}")
    end
  end)
end
