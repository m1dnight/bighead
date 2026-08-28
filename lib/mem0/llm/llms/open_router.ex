defmodule Mem0.LLM.OpenRouter do
  @moduledoc """
  `Mem0.LLM` over OpenRouter's chat-completions API.

  OpenRouter speaks the OpenAI wire format, not Anthropic's, and the
  differences are exactly the facts this adapter exists to absorb:

  - Auth is a bearer token, not an `x-api-key` header.
  - The system prompt is a leading `system`-role message, not a top-level
    field.
  - A schema rides `response_format.json_schema`, which requires a `name` and
    a `strict` flag — and even `strict: true` is enforced per endpoint, not
    guaranteed, so decoders downstream must keep treating replies as claims.
  - A refusal is an HTTP **400** with `error_type: "refusal"` in the error
    metadata — the opposite of Anthropic, where a refusal is a 200.
  - An error can also arrive *inside* a 200 body: once OpenRouter commits a
    response and the upstream provider fails, the failure is delivered as an
    `"error"` object rather than a status code.
  - Usage arrives as `prompt_tokens`/`completion_tokens` and is mapped onto
    the port's `input_tokens`/`output_tokens`.
  - Reasoning effort rides a top-level `reasoning.effort` field. Reasoning
    tokens bill as output tokens and spend from the same `max_tokens` budget
    as the answer — `high` hands roughly 80% of the budget to thinking.
  """

  @behaviour Mem0.LLM

  @endpoint "https://openrouter.ai/api/v1/chat/completions"
  @receive_timeout to_timeout(minute: 2)

  @impl Mem0.LLM
  def complete(request, opts) do
    url = Keyword.get(opts, :base_url, @endpoint)

    req_opts =
      [
        url: url,
        auth: {:bearer, Keyword.fetch!(opts, :api_key)},
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
      {:ok, %Req.Response{status: status, body: body}} -> {:error, error(status, body)}
      {:error, exception} -> {:error, {:transport_error, exception}}
    end
  end

  defp body(request, opts) do
    %{
      model: Keyword.fetch!(opts, :model),
      max_tokens: Map.get(request, :max_tokens) || Keyword.fetch!(opts, :max_tokens),
      messages: messages(request)
    }
    |> put_present(:response_format, response_format(Map.get(request, :schema)))
    |> put_present(:reasoning, reasoning(request, opts))
  end

  # The request's effort wins over the configured one, the same precedence
  # `max_tokens` has. Absent both, the field is omitted entirely and the
  # model's own default stands — an explicit `"none"` is how a caller turns
  # reasoning off, so nil must not be spelled that way.
  defp reasoning(request, opts) do
    case Map.get(request, :effort) || Keyword.get(opts, :effort) do
      nil -> nil
      effort -> %{effort: effort}
    end
  end

  defp messages(request) do
    turns = Enum.map(request.messages, &%{role: Atom.to_string(&1.role), content: &1.content})

    case Map.get(request, :system) do
      nil -> turns
      system -> [%{role: "system", content: system} | turns]
    end
  end

  defp response_format(nil), do: nil

  # The `name` is required by the format and read by nobody; `strict` asks the
  # endpoint to enforce the schema rather than treat it as a hint.
  defp response_format(schema) do
    %{type: "json_schema", json_schema: %{name: "response", strict: true, schema: schema}}
  end

  defp put_present(body, _key, nil), do: body
  defp put_present(body, key, value), do: Map.put(body, key, value)

  # A refusal is a 400, and must stay tellable from "the key is wrong" — the
  # caller's next move differs. Everything else keeps its status and body.
  defp error(_status, %{"error" => %{"metadata" => %{"error_type" => "refusal"}}} = body) do
    {:refusal, get_in(body, ["error", "message"])}
  end

  defp error(status, body), do: {:http_error, status, body}

  # The committed-200-then-upstream-failure case. The error's `code` is the
  # status the response should have carried.
  defp decode(%{"error" => %{"code" => code}} = body) when is_integer(code) do
    {:error, {:http_error, code, body}}
  end

  # OpenAI-style refusals also exist as a `refusal` string on the message —
  # null on every normal reply — and must be checked before content, which a
  # refusing reply may omit.
  defp decode(%{"choices" => [%{"message" => %{"refusal" => refusal}} | _]})
       when is_binary(refusal) and refusal != "" do
    {:error, {:refusal, refusal}}
  end

  defp decode(
         %{"choices" => [%{"message" => %{"content" => content}} | _], "model" => model} = body
       )
       when is_binary(content) and is_binary(model) do
    {:ok, %{content: content, model: model, usage: usage(body)}}
  end

  defp decode(body), do: {:error, {:malformed_response, body}}

  defp usage(body) do
    usage = Map.get(body, "usage") || %{}

    %{
      input_tokens: Map.get(usage, "prompt_tokens", 0),
      output_tokens: Map.get(usage, "completion_tokens", 0)
    }
  end
end
