defmodule Mem0.Embedder do
  @moduledoc """
  The embedded is a behavior that is used to implement an embedding endpoint.

  Embedding of text means generating a vector that can be compared to other
  embeddings to determine of two pieces of texts are similar or not.
  """

  @typedoc """
  Why a call failed.

  The same closed set as `t:Mem0.LLM.reason/0` minus `{:refusal, category}`: an
  embedder has no opinion about what it is asked to embed.
  """
  @type reason ::
          {:http_error, pos_integer(), term()}
          | {:transport_error, term()}
          | {:malformed_response, term()}

  @doc """
  Embeds `texts`, returning one vector per text in the same order.

  An empty list embeds to an empty list without a round trip.
  """
  @callback embed([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, reason()}

  @doc """
  The width of the vectors this adapter produces.

  Exists so that the migration and the runtime agree on one number, and so that
  a stub can declare a width without inventing vectors of the wrong size.
  """
  @callback dimensions(keyword()) :: pos_integer()

  @doc """
  The configured embedder settings, as the adapter expects them.

  One place reads `Application.get_env/2` for this port, and `config/runtime.exs`
  is the only place that reads the environment behind it.
  """
  @spec config() :: keyword()
  def config, do: Application.get_env(:mem0, :embedder, [])

  @doc "The configured adapter module."
  @spec adapter() :: module()
  def adapter, do: Keyword.fetch!(config(), :adapter)

  @doc "Calls `c:embed/2` on the configured adapter. Caller `opts` win."
  @spec embed([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, reason()}
  def embed(texts, opts \\ []) do
    config = config()
    Keyword.fetch!(config, :adapter).embed(texts, Keyword.merge(config, opts))
  end

  @doc "Calls `c:dimensions/1` on the configured adapter. Caller `opts` win."
  @spec dimensions(keyword()) :: pos_integer()
  def dimensions(opts \\ []) do
    config = config()
    Keyword.fetch!(config, :adapter).dimensions(Keyword.merge(config, opts))
  end
end
