defmodule Mem0.LLM.Anthropic do
  @moduledoc """
  `Mem0.LLM` over the Anthropic Messages API.
  """

  @behaviour Mem0.LLM

  @endpoint "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @receive_timeout to_timeout(minute: 2)

  @impl Mem0.LLM
  def complete(request, opts) do
    url = Keyword.get(opts, :base_url, @endpoint)

    req_opts =
      [
        url: url,
        headers: [
          {"x-api-key", Keyword.fetch!(opts, :api_key)},
          {"anthropic-version", @api_version}
        ],
        json: body(request, opts),
        receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout),
        # Retry policy is an open question — where the call sits in a pipeline
        # decides it, and there is no pipeline yet. Off until then, rather than
        # a default that quietly triples the cost of a 429 storm.
        retry: false
      ]
      # `Req.Test` plugs and any other transport-level override arrive here, so
      # the adapter is exercisable end to end without a socket.
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode(body)
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, {:transport_error, exception}}
    end
  end

  @spec body(Mem0.LLM.request(), keyword()) :: map()
  defp body(request, opts) do
    %{
      model: Keyword.fetch!(opts, :model),
      max_tokens: Map.get(request, :max_tokens) || Keyword.fetch!(opts, :max_tokens),
      messages: Enum.map(request.messages, &%{role: Atom.to_string(&1.role), content: &1.content})
    }
    |> put_present(:system, Map.get(request, :system))
    |> put_present(:output_config, schema_config(Map.get(request, :schema)))
  end

  @spec schema_config(map() | nil) :: map() | nil
  defp schema_config(nil), do: nil
  defp schema_config(schema), do: %{format: %{type: "json_schema", schema: schema}}

  @spec put_present(map(), atom(), term()) :: map()
  defp put_present(body, _key, nil), do: body
  defp put_present(body, key, value), do: Map.put(body, key, value)

  # A refusal is a 200. Check it before reading content, which may be absent.
  # `stop_details` is informational and may itself be null, hence `get_in/2`
  # rather than a match: the category is a hint for the caller, not a contract.
  @spec decode(term()) :: {:ok, Mem0.LLM.response()} | {:error, Mem0.LLM.reason()}
  defp decode(%{"stop_reason" => "refusal"} = body) do
    {:error, {:refusal, get_in(body, ["stop_details", "category"])}}
  end

  defp decode(%{"content" => content, "model" => model, "usage" => usage} = body)
       when is_list(content) and is_binary(model) and is_map(usage) do
    case Enum.filter(content, &match?(%{"type" => "text", "text" => t} when is_binary(t), &1)) do
      [] ->
        {:error, {:malformed_response, body}}

      blocks ->
        {:ok,
         %{
           content: Enum.map_join(blocks, &Map.fetch!(&1, "text")),
           model: model,
           usage: %{
             input_tokens: Map.get(usage, "input_tokens", 0),
             output_tokens: Map.get(usage, "output_tokens", 0)
           }
         }}
    end
  end

  defp decode(body), do: {:error, {:malformed_response, body}}
end
