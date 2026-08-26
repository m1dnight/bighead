defmodule Mem0.LLM.OpenRouterTest do
  @moduledoc """
  Turns the API facts in `Mem0.LLM.OpenRouter`'s moduledoc into regression
  tests, the same way `Mem0.LLM.AnthropicTest` does for its adapter. None of
  them needs a socket: the request-shape tests swap in a `Req` adapter module,
  the response-shape tests use `Req.Test`.
  """
  use ExUnit.Case, async: true

  alias Mem0.LLM.OpenRouter

  @opts [api_key: "sk-or-test", model: "anthropic/claude-opus-5", max_tokens: 16_000]

  @request %{messages: [%{role: :user, content: "hello"}]}

  describe "the request it sends" do
    test "authenticates with a bearer token and asks for JSON" do
      request = capture_request(@request, @opts)

      assert Req.Request.get_header(request, "authorization") == ["Bearer sk-or-test"]
      assert Req.Request.get_header(request, "content-type") == ["application/json"]
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

      assert body["model"] == "anthropic/claude-opus-5"
      assert body["max_tokens"] == 16_000

      assert body["messages"] == [
               %{"role" => "user", "content" => "hello"},
               %{"role" => "assistant", "content" => "hi"}
             ]
    end

    test "the system prompt becomes a leading system-role message, not a field" do
      body = capture_body(Map.put(@request, :system, "be terse"), @opts)

      refute Map.has_key?(body, "system")

      assert body["messages"] == [
               %{"role" => "system", "content" => "be terse"},
               %{"role" => "user", "content" => "hello"}
             ]
    end

    test "omits response_format when the request carries no schema" do
      refute Map.has_key?(capture_body(@request, @opts), "response_format")
    end

    test "sends a schema as response_format.json_schema, named and strict" do
      schema = %{"type" => "object", "properties" => %{"fact" => %{"type" => "string"}}}
      body = capture_body(Map.put(@request, :schema, schema), @opts)

      assert body["response_format"] == %{
               "type" => "json_schema",
               "json_schema" => %{"name" => "response", "strict" => true, "schema" => schema}
             }
    end

    test "a per-request max_tokens overrides the configured budget" do
      assert capture_body(Map.put(@request, :max_tokens, 512), @opts)["max_tokens"] == 512
    end

    test "omits reasoning when no effort is configured or requested" do
      refute Map.has_key?(capture_body(@request, @opts), "reasoning")

      # A configured nil is "not sent", not an explicit "none".
      refute Map.has_key?(capture_body(@request, Keyword.put(@opts, :effort, nil)), "reasoning")
    end

    test "a configured effort is sent as reasoning.effort" do
      body = capture_body(@request, Keyword.put(@opts, :effort, "low"))

      assert body["reasoning"] == %{"effort" => "low"}
    end

    test "a per-request effort overrides the configured one" do
      body = capture_body(Map.put(@request, :effort, "high"), Keyword.put(@opts, :effort, "low"))

      assert body["reasoning"] == %{"effort" => "high"}
    end

    test "raises receive_timeout well past Req's default, and lets a caller raise it further" do
      assert capture_request(@request, @opts).options.receive_timeout == to_timeout(minute: 2)

      request = capture_request(@request, Keyword.put(@opts, :receive_timeout, 1_000))
      assert request.options.receive_timeout == 1_000
    end
  end

  describe "the response it decodes" do
    test "returns the text, the usage mapped onto the port's names, and the model" do
      stub_json(%{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "the answer", "refusal" => nil}}
        ],
        "model" => "anthropic/claude-opus-5",
        "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 34, "total_tokens" => 46}
      })

      assert {:ok, response} = OpenRouter.complete(@request, stub_opts())

      assert response == %{
               content: "the answer",
               model: "anthropic/claude-opus-5",
               usage: %{input_tokens: 12, output_tokens: 34}
             }
    end

    test "a refusal string on the message is a refusal, even beside content" do
      stub_json(%{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "", "refusal" => "I can't help"}}
        ],
        "model" => "anthropic/claude-opus-5",
        "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 0}
      })

      assert {:error, {:refusal, "I can't help"}} = OpenRouter.complete(@request, stub_opts())
    end

    test "a 400 tagged error_type refusal is a refusal, not an http_error" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{
            "code" => 400,
            "message" => "the model declined",
            "metadata" => %{"error_type" => "refusal"}
          }
        })
      end)

      assert {:error, {:refusal, "the model declined"}} =
               OpenRouter.complete(@request, stub_opts())
    end

    test "an error inside a 200 body keeps its own code, not the transport's" do
      stub_json(%{
        "error" => %{"code" => 502, "message" => "Provider returned error"}
      })

      assert {:error, {:http_error, 502, body}} = OpenRouter.complete(@request, stub_opts())
      assert body["error"]["message"] == "Provider returned error"
    end

    test "a non-200 carries the status and the body" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"code" => 401, "message" => "invalid key"}})
      end)

      assert {:error, {:http_error, 401, body}} = OpenRouter.complete(@request, stub_opts())
      assert body["error"]["message"] == "invalid key"
    end

    test "a broken connection is a transport error, not a crash" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:transport_error, %Req.TransportError{reason: :econnrefused}}} =
               OpenRouter.complete(@request, stub_opts())
    end

    test "a 200 with null content is malformed, not an empty answer" do
      stub_json(%{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => nil, "refusal" => nil}}
        ],
        "model" => "anthropic/claude-opus-5"
      })

      assert {:error, {:malformed_response, _body}} = OpenRouter.complete(@request, stub_opts())
    end

    test "a 200 that is not a chat completion at all is malformed" do
      stub_json(%{"hello" => "world"})

      assert {:error, {:malformed_response, %{"hello" => "world"}}} =
               OpenRouter.complete(@request, stub_opts())
    end

    test "a missing usage decodes as zero counts rather than crashing" do
      stub_json(%{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "ok", "refusal" => nil}}
        ],
        "model" => "anthropic/claude-opus-5"
      })

      assert {:ok, %{usage: %{input_tokens: 0, output_tokens: 0}}} =
               OpenRouter.complete(@request, stub_opts())
    end
  end

  defp capture_request(request, opts) do
    OpenRouter.complete(request, Keyword.put(opts, :req_options, adapter: Mem0.ReqEcho))

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
