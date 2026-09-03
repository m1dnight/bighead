defmodule Mem0.Embedder.Ollama do
  @moduledoc """
  `Mem0.Embedder` over a local Ollama server.
  """

  @behaviour Mem0.Embedder

  @path "/api/embed"
  @receive_timeout to_timeout(second: 30)

  @type embedding :: [float()]

  @impl Mem0.Embedder
  def embed([], _opts), do: {:ok, []}

  def embed(texts, opts) when is_list(texts) do
    req_opts =
      [
        url: Keyword.fetch!(opts, :base_url) <> @path,
        json: body(texts, opts),
        receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout),
        retry: false
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode(body, length(texts))
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, {:transport_error, exception}}
    end
  end

  @impl Mem0.Embedder
  def dimensions(opts), do: Keyword.fetch!(opts, :dimensions)

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  @spec body([String.t()], keyword()) :: map()
  defp body(texts, opts) do
    base = %{model: Keyword.fetch!(opts, :model), input: texts}

    # Ollama's `truncate` defaults to `true`, which silently shortens an
    # over-long input rather than failing. Whether that is acceptable only shows
    # up with real text, so the choice stays in `opts` rather than being made
    # here — see the open questions in `.plan/03-ports.md`.
    case Keyword.fetch(opts, :truncate) do
      {:ok, truncate} -> Map.put(base, :truncate, truncate)
      :error -> base
    end
  end

  # One vector per input, in order. A short or ragged list means the request and
  # the response disagree about what was asked, which is not something a caller
  # can recover from by looking at the vectors.
  @spec decode(term(), non_neg_integer()) ::
          {:ok, [embedding]} | {:error, {:malformed_response, term()}}
  defp decode(%{"embeddings" => embeddings}, count) when is_list(embeddings) and length(embeddings) == count do
    if Enum.all?(embeddings, &vector?/1) do
      # JSON decodes an exact `0` as an integer, so we normalize them to floats again.
      {:ok, Enum.map(embeddings, fn vector -> Enum.map(vector, &(&1 * 1.0)) end)}
    else
      {:error, {:malformed_response, embeddings}}
    end
  end

  defp decode(body, _count), do: {:error, {:malformed_response, body}}

  @spec vector?(term()) :: boolean()
  defp vector?(vector), do: is_list(vector) and vector != [] and Enum.all?(vector, &is_number/1)
end
