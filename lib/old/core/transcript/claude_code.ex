defmodule Mem0.Core.Transcript.ClaudeCode do
  @moduledoc """
  Turns decoded Claude Code transcript entries into `Mem0.Core.Message` structs.
  """

  alias Mem0.Core.Message
  alias Mem0.Core.Scope

  @typedoc "One decoded JSONL entry, exactly as Claude Code wrote it."
  @type entry :: map()

  @typedoc """
  Why an entry produced no message.

  Ordered as the rules are applied: cheap structural rejections first,
  content-level ones last. An entry gets the *first* reason that applies, which
  is what makes the reason meaningful.
  """
  @type drop ::
          {:unsupported_type, String.t()}
          | :meta
          | :sidechain
          | :synthetic
          | :tool_result
          | :no_text
          | :unparseable_timestamp
          | :malformed

  # A closed allow-list, and it must stay one. Genuine prose in the local corpus
  # opens with `<text>`, `<script>`, `<query>`, `<package>` and `<version>` —
  # people discussing HTML, jq and hex packages — so a "content that looks like
  # a tag" heuristic would eat real messages. An unrecognised wrapper is kept,
  # and the cost of that is noise rather than loss.
  @wrappers ~w(
    command-name command-message command-args local-command-stdout
    local-command-caveat system-reminder ide_opened_file ide_selection
    task-notification
  )

  @doc """
  Normalises decoded transcript entries into messages, oldest first.

  ## Examples

      iex> scope = Scope.new(user_id: "christophe", app_id: "mem0")
      iex> entry = %{
      ...>   "type" => "user",
      ...>   "uuid" => "d7c7af6d",
      ...>   "timestamp" => "2026-08-23T07:45:22.977Z",
      ...>   "origin" => %{"kind" => "human"},
      ...>   "message" => %{"role" => "user", "content" => "show candidates"}
      ...> }
      iex> {[message], []} = ClaudeCode.messages([entry], scope, 41)
      iex> {message.role, message.content, message.seq}
      {:user, "show candidates", 41}

  A slash command is entirely wrapper, so it strips to empty and drops:

      iex> scope = Scope.new(user_id: "christophe")
      iex> entry = %{
      ...>   "type" => "user",
      ...>   "uuid" => "b52c3e14",
      ...>   "timestamp" => "2026-08-21T17:35:10.807Z",
      ...>   "message" => %{
      ...>     "role" => "user",
      ...>     "content" => "<command-name>/effort</command-name>"
      ...>   }
      ...> }
      iex> ClaudeCode.messages([entry], scope)
      {[], [:synthetic]}

  """
  @spec messages([entry()], Scope.t(), non_neg_integer()) :: {[Message.t()], [drop()]}
  def messages(entries, scope, offset \\ 0)

  def messages(entries, %Scope{} = scope, offset)
      when is_list(entries) and is_integer(offset) and offset >= 0 do
    {messages, drops} =
      entries
      |> Enum.with_index(offset)
      |> Enum.reduce({[], []}, fn {entry, seq}, {messages, drops} ->
        case message(entry, scope, seq) do
          {:ok, message} -> {[message | messages], drops}
          {:drop, reason} -> {messages, [reason | drops]}
        end
      end)

    {Enum.reverse(messages), Enum.reverse(drops)}
  end

  # The rules of 4.3, in order. `with` falls through on the first `{:drop, _}`,
  # which is exactly the "first reason that applies" the drop taxonomy promises.
  defp message(entry, scope, seq) when is_map(entry) do
    with {:ok, role} <- role(entry),
         :ok <- reject_meta(entry),
         :ok <- reject_sidechain(entry),
         {:ok, content} <- content(entry, role),
         {:ok, said_at} <- said_at(entry),
         {:ok, id} <- id(entry) do
      {:ok,
       Message.new(
         id: id,
         scope: scope,
         role: role,
         content: content,
         said_at: said_at,
         seq: seq
       )}
    end
  end

  defp message(_entry, _scope, _seq), do: {:drop, :malformed}

  # Rule 1. We are only interested in the users and assistant replies. All the
  # others are unsupported and ignored.
  defp role(%{"type" => "user"}), do: {:ok, :user}
  defp role(%{"type" => "assistant"}), do: {:ok, :assistant}
  defp role(%{"type" => type}) when is_binary(type), do: {:drop, {:unsupported_type, type}}
  defp role(_entry), do: {:drop, :malformed}

  # Rule 2. Ignore meta and compaction summaries.
  defp reject_meta(%{"isMeta" => true}), do: {:drop, :meta}
  defp reject_meta(%{"isCompactSummary" => true}), do: {:drop, :meta}
  defp reject_meta(_entry), do: :ok

  # Rule 3. For now we ignore side chains. These are a TODO for later.
  defp reject_sidechain(%{"isSidechain" => true}), do: {:drop, :sidechain}
  defp reject_sidechain(_entry), do: :ok

  # Extract the content from the message.
  defp content(%{"message" => message} = entry, role) when is_map(message) do
    case blocks(Map.get(message, "content")) do
      {:ok, blocks} -> spoken(blocks, entry, role)
      :error -> {:drop, :malformed}
    end
  end

  defp content(_entry, _role), do: {:drop, :malformed}

  # A `user` entry's content may be a bare string or a block list; both are
  # normal and both must parse. Non-map elements of a block list are ignored
  # rather than fatal.
  defp blocks(content) when is_binary(content) do
    {:ok, [%{"type" => "text", "text" => content}]}
  end

  defp blocks(content) when is_list(content) do
    {:ok, Enum.filter(content, &is_map/1)}
  end

  defp blocks(_content), do: :error

  # What survives inside a kept entry: `text` becomes the content, `thinking`
  # and `tool_use` are dropped — the one is not said to anyone, the other is a
  # function call rather than an utterance.
  defp spoken(blocks, entry, role) do
    said = blocks |> Enum.filter(&text_block?/1) |> Enum.map_join("\n", & &1["text"])
    stripped = if role == :user, do: strip_wrappers(said), else: said

    with :ok <- reject_synthetic(entry, role, said, stripped),
         :ok <- reject_tool_result(blocks) do
      case String.trim(stripped) do
        "" -> {:drop, :no_text}
        text -> {:ok, text}
      end
    end
  end

  defp text_block?(%{"type" => "text", "text" => text}) when is_binary(text), do: true
  defp text_block?(_block), do: false

  # Rule 4. `role: "user"` does not mean "a person typed this" — Claude Code
  # puts slash-command invocations, their stdout, `<system-reminder>` blocks,
  # IDE context and subagent briefs in the user turn, because that is the only
  # envelope the Messages API gives it.
  #
  # Two *independent* tests, and an entry must pass both. A fallback chain would
  # need to distinguish "`origin` absent because the version is old" from
  # "absent because the entry is synthetic", and nothing in the payload answers
  # that. Neither test needs to know: the wrapper strip is version-independent,
  # and the origin check simply does not fire when `origin` is absent.
  #
  # Note the `said != ""` guard. An entry that *strips* to empty is machine
  # text; an entry that had no text to begin with is something else, and falls
  # through to `:tool_result` or `:no_text`. Conflating the two hides both.
  defp reject_synthetic(entry, :user, said, stripped) do
    trimmed = String.trim(stripped)

    if machine_origin?(entry) or (String.trim(said) != "" and trimmed == "") or
         slash_command?(trimmed) do
      {:drop, :synthetic}
    else
      :ok
    end
  end

  defp reject_synthetic(_entry, _role, _said, _stripped), do: :ok

  # A slash command the user typed reaches the transcript twice: once as the raw
  # text they typed, and once in `<command-name>` form. The wrapper copy strips
  # to empty and drops above; this catches the raw echo, which carries no
  # wrapper and — measured on a v2.1.241 `/compact` — no `origin` either, so
  # neither test above fires on it.
  #
  # An exact match on one `/token`, not a prefix test: `\w` excludes `/`, so a
  # path like `/dev/ingest` is not a command and a sentence that merely opens
  # with a slash keeps its text. Measured across the corpus: one entry in 169
  # kept user messages matches, and no message a person meant does.
  defp slash_command?(text), do: Regex.match?(~r{\A/[A-Za-z][\w:-]*\z}, text)

  # `origin.kind` is vendor data and stays a binary. The set of non-human values
  # is open — `task-notification` is the one seen — so this tests for "not
  # human" rather than allow-listing what a machine may say.
  defp machine_origin?(%{"origin" => %{"kind" => kind}}) when is_binary(kind), do: kind != "human"
  defp machine_origin?(_entry), do: false

  # Rule 5. In the transcript a tool result arrives as a `type: "user"` entry,
  # because that is how the Messages API carries it. Keeping it would mean
  # feeding extraction a "user message" whose content is a directory listing or
  # a 4000-line file — where nearly all the tokens live and nearly none of the
  # facts, and the failure is silent.
  defp reject_tool_result(blocks) do
    if Enum.any?(blocks, &match?(%{"type" => "tool_result"}, &1)),
      do: {:drop, :tool_result},
      else: :ok
  end

  # Rule 7. A missing timestamp gets the same reason as an unreadable one: both
  # are entries whose `said_at` is unknown, and neither may be invented.
  defp said_at(%{"timestamp" => timestamp}) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, said_at, _offset} -> {:ok, said_at}
      {:error, _reason} -> {:drop, :unparseable_timestamp}
    end
  end

  defp said_at(_entry), do: {:drop, :unparseable_timestamp}

  # Rule 8. `uuid` is the entry's identity in the transcript.
  defp id(%{"uuid" => uuid}) when is_binary(uuid) do
    case String.trim(uuid) do
      "" -> {:drop, :malformed}
      id -> {:ok, id}
    end
  end

  defp id(_entry), do: {:drop, :malformed}

  # Remove all the wrappers from wrapped blocks that we want to keep. For
  # example <foo>bar</foo> will result in "foo" with the tags removed.
  defp strip_wrappers(text) do
    Enum.reduce(@wrappers, text, fn tag, stripped ->
      stripped
      |> strip_pairs("<#{tag}>", "</#{tag}>")
      |> strip_orphan_close("</#{tag}>")
    end)
  end

  # The wrappers are not well-formed XML and are not always balanced: a dangling
  # `<ide_selection>` with no close occurs in real transcripts. So a known
  # opening tag strips to end-of-input rather than requiring a pair.
  defp strip_pairs(text, open, close) do
    case String.split(text, open, parts: 2) do
      [unchanged] ->
        unchanged

      [before, rest] ->
        case String.split(rest, close, parts: 2) do
          [_unterminated] -> before
          [_inside, after_close] -> strip_pairs(before <> after_close, open, close)
        end
    end
  end

  # An orphan closing tag with no open occurs too. Only a *leading* one is
  # stripped: mid-text, everything before it is the block's own body, and
  # discarding that far on an unbalanced tag is how a real message gets eaten.
  defp strip_orphan_close(text, close) do
    text
    |> String.trim_leading()
    |> String.split(close, parts: 2)
    |> case do
      ["", rest] -> strip_orphan_close(rest, close)
      _no_leading_close -> text
    end
  end
end
