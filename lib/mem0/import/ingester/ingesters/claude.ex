defmodule Bighead.Ingester.Claude do
  @moduledoc """
  Ingests JSON entries form transcripts in a Claude chat, and converts them to
  `t:Bighead.Ingester.message/0` maps.
  """

  @behaviour Bighead.Ingester

  alias Bighead.Ingester.Decoder

  # The entry `type`s that are bookkeeping rather than conversation.
  @machinery_types ~w(
    permission-mode atis-latch last-prompt attachment frame-link
    queue-operation ai-title system mode file-history-snapshot
    artifact-autoreact-ledger file-history-delta artifact-comment-monitor
    started
  )

  @impl true
  # some types are ignored.
  def skip_entry?(%{"type" => type}) when type in @machinery_types do
    true
  end

  # meta messages are also ignored.
  def skip_entry?(%{"isMeta" => true}) do
    true
  end

  def skip_entry?(%{"type" => _type, "uuid" => _uuid}) do
    false
  end

  def skip_entry?(_entry) do
    true
  end

  @impl true
  def parse_entry(entry) when is_map(entry) do
    with {:ok, id} <- Map.fetch(entry, "uuid"),
         {:ok, timestamp} <- Map.fetch(entry, "timestamp"),
         {:ok, timestamp, _} <- DateTime.from_iso8601(timestamp),
         {:ok, role} <- Map.fetch(entry, "type"),
         {:ok, content} <- Map.fetch(entry, "message"),
         {:ok, contents} <- Map.fetch(content, "content") do
      content = Decoder.decode_contents(contents)

      {:ok,
       %{
         id: id,
         role: role,
         content: content,
         timestamp: timestamp
       }}
    else
      _ ->
        {:error, :decode_failed}
    end
  end

  # for claude, we rely on the session and cwd attached to each message.
  @impl true
  def scope(entries) do
    entries
    |> Enum.reduce(%{}, fn entry, scope ->
      case entry do
        %{"cwd" => cwd, "sessionId" => session, "type" => "user"} ->
          scope
          |> Map.put_new(:session, session)
          |> Map.put_new(:project, cwd)

        _ ->
          scope
      end
    end)
    |> case do
      %{session: session, project: cwd} ->
        {:ok, %{session: session, project: cwd}}

      %{session: _} ->
        {:error, :no_project}

      %{} ->
        {:error, :no_session}
    end
  end
end
