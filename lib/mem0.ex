defmodule Mem0 do
  @moduledoc """
  Mem0 keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
  alias Mem0.Ingester.Claude
  alias Mem0.Ingester.Codex
  alias Mem0.Store.Scopes

  def import do
    run_import(".transcripts/claude/*.jsonl", Claude)
    run_import(".transcripts/codex/*.jsonl", Codex)
  end

  def process_all_sessions do
    Scopes.list()
    |> Enum.map(& &1.session)
    |> Enum.dedup()
    |> Enum.map(fn session ->
      Mem0.Processor.process_session(session)
    end)
  end

  def run_import(path, ingester) do
    Path.wildcard(path)
    |> Enum.map(fn path ->
      content = File.read!(path)

      case Mem0.Importer.import_transcript(content, ingester) do
        {:ok, _messages} ->
          :ok

        err ->
          IO.puts(inspect(err, pretty: true, limit: 1000))
      end
    end)
  end
end
