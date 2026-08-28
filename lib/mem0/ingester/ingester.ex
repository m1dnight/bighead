defmodule Mem0.Ingester do
  @moduledoc """
  An ingester is what takes in raw transcript json from an agent, and parses it
  into messages we care about.
  """

  @typedoc """
  The shape into which all messages from all agents have to be put in order
  for them to go further into the Mem0 pipeline.

  A plain map rather than a struct: it is fed into
  `Mem0.Store.Message.changeset/2` as attrs, so `role` stays the raw string
  the changeset validates.
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

  @spec decode_transcript(String.t(), module()) ::
          {:ok, scope(), [message()]} | {:error, term()}
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

  @spec decode_lines(String.t()) :: {:ok, [map()]} | {:error, {:invalid_line, pos_integer()}}
  defp decode_lines(lines) do
    lines
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, entries} ->
      case Jason.decode(line) do
        {:ok, entry} ->
          {:cont, {:ok, [entry | entries]}}

        {:error, _undecodable} ->
          {:halt, {:error, {:invalid_line, number}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp extract_messages(entries, ingester) do
    entries
    |> Enum.reject(&ingester.skip_entry?/1)
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, messages} ->
      case ingester.parse_entry(entry) do
        {:ok, %{content: ""}} ->
          {:cont, {:ok, messages}}

        {:ok, message} ->
          {:cont, {:ok, [message | messages]}}

        {:error, err} ->
          {:halt, {:error, err}}
      end
    end)
    |> case do
      {:ok, messages} ->
        {:ok, Enum.reverse(messages)}

      {:error, _err} ->
        {:error, :message_extract_failed}
    end
  end
end
