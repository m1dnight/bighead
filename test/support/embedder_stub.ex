defmodule Bighead.Embedder.Stub do
  @moduledoc """
  `Bighead.Embedder` that returns deterministic vectors and records what it was asked.

  Lives in `test/support/` rather than `lib/` for the same reason
  `Bighead.LLM.Stub` does. `config/test.exs` points `:embedder` here.

  The default reply derives each vector from a SHA-256 of the text, so equal
  texts embed equally and different texts do not — enough structure for a
  retrieval test to be meaningful without any of it being a real embedding. The
  width comes from the configured `:dimensions`, so a stub can never hand the
  `vector(N)` column the wrong shape.
  """

  @behaviour Bighead.Embedder

  alias Bighead.PortStub

  @key :bighead_embedder_stub

  @doc """
  Starts the stub for this test.

  `:reply` is a `{:ok, vectors}`, an `{:error, reason}`, or a two-argument
  function of the texts and the options. Defaults to `deterministic/2`.
  """
  @spec start!(keyword()) :: pid()
  def start!(opts \\ []) do
    PortStub.start!(@key, Keyword.get(opts, :reply, &deterministic/2))
  end

  @doc "Replaces the reply mid-test."
  @spec set(PortStub.reply()) :: :ok
  def set(reply), do: PortStub.set(@key, reply)

  @doc "Every list of texts the stub received, oldest first."
  @spec calls() :: [[String.t()]]
  def calls, do: PortStub.calls(@key)

  @doc """
  One vector per text, stable across runs and derived only from the text.

  This is the default reply, exposed so a test that overrides `:reply` for one
  call can still fall back to it for the others.
  """
  @spec deterministic([String.t()], keyword()) :: {:ok, [[float()]]}
  def deterministic(texts, opts) do
    width = dimensions(opts)
    {:ok, Enum.map(texts, &vector(&1, width))}
  end

  @impl Bighead.Embedder
  def embed(texts, opts), do: PortStub.call(@key, texts, opts)

  @impl Bighead.Embedder
  def dimensions(opts), do: Keyword.get(opts, :dimensions, 768)

  defp vector(text, width) do
    :sha256
    |> :crypto.hash(text)
    |> :binary.bin_to_list()
    |> Stream.cycle()
    |> Enum.take(width)
    # A byte, mapped onto [-1.0, 1.0). Not a unit vector and not meant to be —
    # cosine similarity only needs directions that differ.
    |> Enum.map(&(&1 / 128.0 - 1.0))
  end
end
