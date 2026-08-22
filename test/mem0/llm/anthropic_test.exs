defmodule Mem0.LLM.AnthropicTest do
  @moduledoc """
  Turns the five API facts in `Mem0.LLM.Anthropic`'s moduledoc into regression
  tests. These are the behaviours that are expensive to discover in production,
  and none of them needs a socket: the request-shape tests swap in a `Req`
  adapter module, the response-shape tests use `Req.Test`.
  """
  use ExUnit.Case, async: true

  alias Mem0.LLM.Anthropic

  @opts [api_key: "sk-ant-test", model: "claude-opus-5", max_tokens: 16_000]

  @request %{messages: [%{role: :user, content: "hello"}]}

  describe "the request it sends" do
    test "carries the key and the API version, and asks for JSON" do
      request = capture_request(@request, @opts)

      assert Req.Request.get_header(request, "x-api-key") == ["sk-ant-test"]
      assert Req.Request.get_header(request, "anthropic-version") == ["2023-06-01"]
      assert Req.Request.get_header(request, "content-type") == ["application/json"]
    end

    test "sends no sampling knobs, because Claude Opus 5 rejects them with a 400" do
      body = capture_body(@request, @opts)

      refute Map.has_key?(body, "temperature")
      refute Map.has_key?(body, "top_p")
      refute Map.has_key?(body, "top_k")
    end

    test "sends the model, the token budget and the messages" do
      body =
        capture_body(
          %{
            messages: [
              %{role: :user, content: "hello"},
              %{role: :assistant, content: "hi"}
            ]
          },
          @opts
        )

      assert body["model"] == "claude-opus-5"
      assert body["max_tokens"] == 16_000

      assert body["messages"] == [
               %{"role" => "user", "content" => "hello"},
               %{"role" => "assistant", "content" => "hi"}
             ]
    end

    test "omits system and output_config when the request does not carry them" do
      body = capture_body(@request, @opts)

      refute Map.has_key?(body, "system")
      refute Map.has_key?(body, "output_config")
    end

    test "sends a schema as output_config.format, not the deprecated output_format" do
      schema = %{"type" => "object", "properties" => %{"fact" => %{"type" => "string"}}}
      body = capture_body(Map.put(@request, :schema, schema), @opts)

      assert body["output_config"] == %{
               "format" => %{"type" => "json_schema", "schema" => schema}
             }

      refute Map.has_key?(body, "output_format")
    end

    test "a per-request max_tokens overrides the configured budget" do
      assert capture_body(Map.put(@request, :max_tokens, 512), @opts)["max_tokens"] == 512
    end

    test "raises receive_timeout well past Req's default, and lets a caller raise it further" do
      # Req's default is 15s; a thinking model on a long prompt exceeds it, and
      # the failure looks like a network fault rather than a timeout.
      assert capture_request(@request, @opts).options.receive_timeout == to_timeout(minute: 2)

      request = capture_request(@request, Keyword.put(@opts, :receive_timeout, 1_000))
      assert request.options.receive_timeout == 1_000
    end
  end

  describe "the response it decodes" do
    test "returns the text, the usage and the model that actually answered" do
      stub_json(%{
        "content" => [%{"type" => "text", "text" => "the answer"}],
        "model" => "claude-opus-5",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 12, "output_tokens" => 34}
      })

      assert {:ok, response} = Anthropic.complete(@request, stub_opts())

      assert response == %{
               content: "the answer",
               model: "claude-opus-5",
               usage: %{input_tokens: 12, output_tokens: 34}
             }
    end

    test "skips thinking blocks, which precede text and are on by default" do
      stub_json(%{
        "content" => [
          %{"type" => "thinking", "thinking" => "", "signature" => "abc"},
          %{"type" => "text", "text" => "first"},
          %{"type" => "text", "text" => " and second"}
        ],
        "model" => "claude-opus-5",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
      })

      assert {:ok, %{content: "first and second"}} = Anthropic.complete(@request, stub_opts())
    end

    test "a refusal is an HTTP 200 and must not be read as content" do
      stub_json(%{
        "content" => [],
        "model" => "claude-opus-5",
        "stop_reason" => "refusal",
        "stop_details" => %{"type" => "refusal", "category" => "cyber"},
        "usage" => %{"input_tokens" => 7, "output_tokens" => 0}
      })

      assert {:error, {:refusal, "cyber"}} = Anthropic.complete(@request, stub_opts())
    end

    test "a refusal with no stop_details still decodes, without a category" do
      stub_json(%{
        "content" => [],
        "model" => "claude-opus-5",
        "stop_reason" => "refusal",
        "stop_details" => nil,
        "usage" => %{"input_tokens" => 7, "output_tokens" => 0}
      })

      assert {:error, {:refusal, nil}} = Anthropic.complete(@request, stub_opts())
    end

    test "a mid-stream refusal is a refusal, not the partial text" do
      stub_json(%{
        "content" => [%{"type" => "text", "text" => "here is how to"}],
        "model" => "claude-opus-5",
        "stop_reason" => "refusal",
        "stop_details" => %{"type" => "refusal", "category" => "bio"},
        "usage" => %{"input_tokens" => 7, "output_tokens" => 5}
      })

      assert {:error, {:refusal, "bio"}} = Anthropic.complete(@request, stub_opts())
    end

    test "a non-200 carries the status and the body" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"type" => "authentication_error"}})
      end)

      assert {:error, {:http_error, 401, body}} = Anthropic.complete(@request, stub_opts())
      assert body["error"]["type"] == "authentication_error"
    end

    test "a broken connection is a transport error, not a crash" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:transport_error, %Req.TransportError{reason: :econnrefused}}} =
               Anthropic.complete(@request, stub_opts())
    end

    test "a 200 with no text block at all is malformed, not an empty answer" do
      stub_json(%{
        "content" => [%{"type" => "thinking", "thinking" => "", "signature" => "abc"}],
        "model" => "claude-opus-5",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      })

      assert {:error, {:malformed_response, _body}} = Anthropic.complete(@request, stub_opts())
    end

    test "a 200 that is not a Messages response at all is malformed" do
      stub_json(%{"hello" => "world"})

      assert {:error, {:malformed_response, %{"hello" => "world"}}} =
               Anthropic.complete(@request, stub_opts())
    end
  end

  @tag :live
  test "a well-formed call round-trips against the real API" do
    config = Application.fetch_env!(:mem0, :live_llm)

    assert config[:api_key], "ANTHROPIC_API_KEY is not set; mix test.live needs it"

    request = %{
      messages: [%{role: :user, content: "Reply with the single word: pong"}],
      system: "You reply with exactly one word and no punctuation.",
      max_tokens: 1_024
    }

    assert {:ok, response} = Anthropic.complete(request, config)
    assert response.content =~ ~r/pong/i
    assert response.usage.output_tokens > 0
    assert response.model =~ "claude"
  end

  # `Mem0.ReqEcho` replaces the transport and hands the built request back. It
  # is the only place options like `receive_timeout` are still visible — a
  # `Plug` sees the socket-level request, not Req's configuration.
  defp capture_request(request, opts) do
    Anthropic.complete(request, Keyword.put(opts, :req_options, adapter: Mem0.ReqEcho))

    assert_received {:req_request, req}
    req
  end

  defp capture_body(request, opts) do
    request
    |> capture_request(opts)
    |> Map.fetch!(:body)
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end

  defp stub_json(body), do: Req.Test.stub(__MODULE__, &Req.Test.json(&1, body))

  defp stub_opts, do: Keyword.put(@opts, :req_options, plug: {Req.Test, __MODULE__})
end
