defmodule Mem0.Ingester do
  @moduledoc """
  An ingester is what takes in raw transcript json from an agent, and parses it
  into messages we care about.
  """

  alias Mem0.Ingester.Message

  @doc """
  Parses a map into a `Message` struct for further processing.
  """
  @callback parse_entry(entry :: map()) :: {:ok, Message.t()} | {:error, term()}

  @doc """
  Given a decoded entry, checks if this entry should be discarded or not.
  """
  @callback skip_entry?(entry :: map()) :: boolean()

  @doc """
  Given a list of decoded entries, determines the scope for these lines.

  This function assumes that all the given entries belong to a single
  transcript, and it only expects to return a single scope.
  """
  @callback scope(entries :: [map()]) :: {:ok, map()} | {:error, term()}

  @spec decode_transcript(String.t(), module()) :: {:ok, map(), [Message.t()]} | {:error, term()}
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
