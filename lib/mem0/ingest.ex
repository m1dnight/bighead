defmodule Mem0.Ingest do
  @moduledoc """
  Ingests messages form an LLM into our domain structs (i.e., Message).

  """

  alias Mem0.Core.Message
  alias Mem0.Core.Scope
  alias Mem0.Core.Transcript.ClaudeCode

  # An install with no configuration should ingest: there is nothing to protect
  # yet, and a hard failure at boot is a worse first experience than a memory
  # filed under a placeholder name. See `config/runtime.exs`.
  @default_user_id "local"

  @doc """
  The server-side `user_id` every ingested message is attributed to.

  One value today, and the argument to `receive/2` exists anyway: that is what
  makes bearer-token auth a change to this module's *caller* rather than to this
  module. A blank configured value falls back rather than raising, for the
  reason in the module doc.
  """
  @spec default_user_id() :: String.t()
  def default_user_id do
    :mem0
    |> Application.get_env(:hook, [])
    |> Keyword.get(:default_user_id)
    |> case do
      value when is_binary(value) -> blank_to_default(String.trim(value))
      _not_configured -> @default_user_id
    end
  end

  # The curent app id is the CWD of the session's basename, or nil.
  defp app_id(%{"cwd" => cwd}) when is_binary(cwd) do
    case String.trim(cwd) do
      "" -> nil
      trimmed -> Path.basename(trimmed)
    end
  end

  defp app_id(_payload), do: nil

  defp run_id(%{"session_id" => run_id}) when is_binary(run_id), do: run_id
  defp run_id(%{"sessionId" => run_id}) when is_binary(run_id), do: run_id
  defp run_id(_payload), do: nil

  defp blank_to_default(""), do: @default_user_id
  defp blank_to_default(user_id), do: user_id

  @doc """
  Ingests a transcript that was sent over that needs to be massaged into a
  generic format for storage/ingestion.

  It expects a field `transcript_length` set by the hook script. This is the
  total amount of entries being sent and allows Mem0 to recompute the offset and
  absolute message numbering.

   - Fetch the entries from the message list.
   - Compute their absolute index for the messages in this scope.
  """
  @spec receive(payload :: map(), user_id :: String.t()) ::
          {:ok, [Message.t()], [ClaudeCode.drop()]} | {:error, term()}
  def receive(payload, user_id) when is_map(payload) and is_binary(user_id) do
    with {:ok, entries} <- entries(payload),
         :ok <- check_length(entries, payload),
         {:ok, offset} <- offset(payload) do
      scope = scope(payload, user_id)

      {duration, {messages, drops}} =
        :timer.tc(ClaudeCode, :messages, [entries, scope, offset])

      measure(payload, scope, length(entries), messages, drops, duration)

      {:ok, messages, drops}
    end
  end

  def receive(_payload, _user_id), do: {:error, :invalid_payload}

  defp entries(%{"entries" => entries}) when is_list(entries), do: {:ok, entries}
  defp entries(%{"entries" => _not_a_list}), do: {:error, :invalid_entries}
  defp entries(_payload), do: {:error, :no_entries}

  defp check_length(entries, %{"transcript_length" => sent}) when is_integer(sent) do
    case length(entries) do
      ^sent -> :ok
      received -> {:error, {:length_mismatch, sent, received}}
    end
  end

  defp check_length(_entries, _payload), do: {:error, :missing_transcript_length}

  # Computes the absolute index for each message in this chunk of transcript.
  # The total transcript length is the total line count of the full transcript,
  # and transcript length is the amount of messages sent here.  This allows us
  # to compute the absolute indices.
  defp offset(%{"total_transcript_length" => total, "transcript_length" => sent})
       when is_integer(total) and is_integer(sent) do
    case total - sent do
      offset when offset >= 0 -> {:ok, offset}
      negative -> {:error, {:invalid_offset, negative}}
    end
  end

  defp offset(_payload), do: {:error, :missing_transcript_length}

  @doc """
  The address a hook payload writes to, for the given server-side `user_id`.

  Public because a payload's scope is needed without ingesting it: a sender
  asking where its stored copy ends is addressing the same run, and deriving
  that address a second way is how the two drift apart.
  """
  @spec scope(payload :: map(), user_id :: String.t()) :: Scope.t()
  def scope(payload, user_id) when is_map(payload) and is_binary(user_id) do
    Scope.new(user_id: user_id, app_id: app_id(payload), run_id: run_id(payload))
  end

  defp hook_event(%{"hook_event_name" => name}) when is_binary(name), do: name
  defp hook_event(_payload), do: "unknown"

  # Counts and identifiers, no content — the same rule the LLM telemetry
  # follows. See the redaction policy in `config/config.exs`.
  defp measure(payload, scope, entries, messages, drops, duration) do
    :telemetry.execute(
      [:mem0, :ingest, :received],
      %{
        entries: entries,
        messages: length(messages),
        dropped: length(drops),
        duration: duration
      },
      %{
        user_id: scope.user_id,
        app_id: scope.app_id,
        run_id: scope.run_id,
        hook_event: hook_event(payload),
        drops: tally(drops)
      }
    )
  end

  # Broken out by reason, and `{:unsupported_type, type}` bucketed by the type
  # string rather than aggregated: rule 1 of the normaliser drops more than half
  # of every batch as a matter of routine, so one aggregate counter would bury a
  # genuinely new type under that known-constant majority. A bucket that did not
  # exist last week is the signal that Claude Code's format moved.
  #
  # Keys are binaries. `type` comes from a vendor payload, and interning it
  # would grow the atom table without bound.
  defp tally(drops) do
    Enum.reduce(drops, %{}, fn drop, tally -> Map.update(tally, reason(drop), 1, &(&1 + 1)) end)
  end

  defp reason({:unsupported_type, type}), do: "unsupported_type:" <> type
  defp reason(atom) when is_atom(atom), do: Atom.to_string(atom)
end
