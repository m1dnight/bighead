defmodule Mem0.Ingester do
  @moduledoc """
  An ingester is what takes in raw transcript json from an agent, and parses it
  into messages we care about.
  """

  import Util

  require Logger

  @typedoc """
  The shape into which all messages from all agents have to be put in order for
  them to go further into the Mem0 pipeline. This means that transcripts from
  Claude, Codex, .. all have to be able to be transformed into this shape.
  """
  @type message :: %{
          id: String.t() | nil,
          role: String.t(),
          content: String.t(),
          timestamp: DateTime.t()
        }

  @typedoc """
  The scope a transcript belongs to, as attrs for
  `Mem0.Store.Scope.changeset/2`.
  """
  @type scope :: %{project: String.t(), session: String.t()}

  @doc """
  Parses a raw entry into a `t:message/0` map for further processing.
  """
  @callback parse_entry(entry :: map()) :: {:ok, message()} | {:error, term()}

  @doc """
  Given a decoded entry, checks if this entry should be discarded or not.
  """
  @callback skip_entry?(entry :: map()) :: boolean()

  @doc """
  Given a list of decoded entries, determines the scope for these lines.

  This function assumes that all the given entries belong to a single
  transcript, and it only expects to return a single scope.
  """
  @callback scope(entries :: [map()]) :: {:ok, scope()} | {:error, term()}

  @doc """
  Given a string that represents the contents of a jsonl transcript, decodes
  each line into a message and returns a list of `message()`s.
  """
  @spec decode_transcript(String.t(), module()) :: {:ok, scope(), [message()]} | {:error, term()}
  def decode_transcript(content, ingester) do
    with {:ok, entries} <- decode_lines(content),
         {:ok, scope} <- ingester.scope(entries),
         {:ok, messages} <- extract_messages(entries, ingester) do
      {:ok, scope, messages}
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  @spec decode_lines(String.t()) :: {:ok, [map()]} | {:error, :decode_failed}
  defp decode_lines(lines) do
    lines
    |> String.split("\n", trim: true)
    |> traverse(&Jason.decode/1)
    |> case do
      {:ok, entries} ->
        {:ok, entries}

      {:error, _reason} ->
        {:error, :decode_failed}
    end
  end

  # Never errors: entries that fail to parse are logged and dropped, the rest
  # of the transcript still imports.
  @spec extract_messages([map()], module()) :: {:ok, [message()]}
  defp extract_messages(entries, ingester) do
    entries
    |> Enum.reject(&ingester.skip_entry?/1)
    |> partition_map(&ingester.parse_entry/1)
    |> case do
      {messages, []} ->
        {:ok, messages}

      {messages, failed} ->
        Logger.warning("Failed to import some messages: #{inspect(failed)}")
        {:ok, messages}
    end
  end
end
