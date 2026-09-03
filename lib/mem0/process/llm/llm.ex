defmodule Bighead.LLM do
  @moduledoc """
  An LLM behavior used to execute regular text prompts and get back a result.
  """

  @typedoc "One turn of a conversation sent to the model."
  @type message :: %{role: :user | :assistant, content: String.t()}

  @typedoc """
  A completion request.

  `:schema` carries a JSON Schema through to the provider's structured-output
  mechanism. It is optional because not every call needs one, and its absence
  must mean "plain text" rather than "empty schema".

  `:max_tokens` overrides the configured default for one call. It caps thinking
  *plus* response text together on a thinking model, so it is a budget rather
  than a length.

  `:effort` overrides the configured reasoning effort for one call — one of
  `t:effort/0`, spending a larger or smaller share of the `:max_tokens` budget
  on thinking. An adapter with no effort mechanism ignores it; today only
  `Bighead.LLM.OpenRouter` reads it.
  """
  @type request :: %{
          required(:messages) => [message()],
          optional(:system) => String.t(),
          optional(:schema) => map(),
          optional(:max_tokens) => pos_integer(),
          optional(:effort) => effort()
        }

  @typedoc """
  A reasoning-effort level, highest to lowest; `"none"` disables reasoning.

  OpenRouter's vocabulary, kept as strings because that is how the value
  arrives from configuration and leaves on the wire. Effort-based models take
  it natively; budget-based models (Claude, Gemini thinking) have it mapped
  onto a share of `max_tokens` by the provider.
  """
  @type effort :: String.t()

  @typedoc "Token counts for one call. Metadata only — never the payload."
  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}

  @typedoc """
  A successful completion.

  `:model` is what the provider says answered, not what was asked for; the two
  can differ and the difference is worth keeping.
  """
  @type response :: %{content: String.t(), usage: usage(), model: String.t()}

  @typedoc """
  Why a call failed.

  A closed set for the same reason `Bighead.Core.MemoryOperation`'s reason type is
  one: a caller that must branch on failure needs to tell "the model declined"
  from "the network broke" from "the key is wrong", and `t:term/0` documents
  none of it.

  `{:refusal, category}` is the one that surprises people. A refusal arrives as
  HTTP 200 with empty or partial content, so it is a success at the transport
  layer and a failure here.
  """
  @type reason ::
          {:refusal, String.t() | nil}
          | {:http_error, pos_integer(), term()}
          | {:transport_error, term()}
          | {:malformed_response, term()}

  @doc """
  Sends `request` to the model and returns its text.

  `opts` carries the adapter's configuration — API key, model, timeouts — as a
  keyword list rather than reading it from the application environment, which is
  what makes an adapter testable.
  """
  @callback complete(request(), keyword()) :: {:ok, response()} | {:error, reason()}

  @doc """
  The configured LLM settings, as the adapter expects them.

  One place reads `Application.get_env/2` for this port, and `config/runtime.exs`
  is the only place that reads the environment behind it.
  """
  @spec config() :: keyword()
  def config, do: Application.get_env(:bighead, :llm, [])

  @doc "The configured adapter module."
  @spec adapter() :: module()
  def adapter, do: Keyword.fetch!(config(), :adapter)

  @doc """
  Calls `c:complete/2` on the configured adapter.

  Caller-supplied `opts` win over the configured ones, so a single call can
  raise a timeout or override the model without touching configuration.
  """
  @spec complete(request(), keyword()) :: {:ok, response()} | {:error, reason()}
  def complete(request, opts \\ []) do
    config = config()
    Keyword.fetch!(config, :adapter).complete(request, Keyword.merge(config, opts))
  end
end
