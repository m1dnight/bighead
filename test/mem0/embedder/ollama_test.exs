defmodule Mem0.Embedder.OllamaTest do
  @moduledoc """
  Ollama has two endpoints one character apart with different field names in
  both directions, so the request-shape tests here are the ones that matter: a
  regression to `/api/embeddings` would still return 200 and still return
  vectors, just one at a time and under a different key.
  """
  use ExUnit.Case, async: true

  alias Mem0.Embedder.Ollama

  @opts [base_url: "http://localhost:11434", model: "nomic-embed-text", dimensions: 768]

  describe "the request it sends" do
    test "posts to /api/embed, not the deprecated /api/embeddings" do
      assert capture_request(["a"], @opts).url.path == "/api/embed"
    end

    test "sends the batch under `input`, which is what /api/embed takes" do
      body = capture_body(["first", "second"], @opts)

      assert body == %{"model" => "nomic-embed-text", "input" => ["first", "second"]}
      refute Map.has_key?(body, "prompt")
    end

    test "sends no authentication header, because Ollama is local" do
      request = capture_request(["a"], @opts)

      assert Req.Request.get_header(request, "authorization") == []
      assert Req.Request.get_header(request, "x-api-key") == []
    end

    test "omits truncate unless a caller asks for it" do
      refute Map.has_key?(capture_body(["a"], @opts), "truncate")
      assert capture_body(["a"], Keyword.put(@opts, :truncate, false))["truncate"] == false
    end

    test "an empty batch costs no round trip" do
      assert {:ok, []} = Ollama.embed([], Keyword.put(@opts, :req_options, adapter: Mem0.ReqEcho))
      refute_received {:req_request, _request}
    end
  end

  describe "the response it decodes" do
    test "returns one vector per input, in order" do
      stub_json(%{"embeddings" => [[0.1, 0.2], [0.3, 0.4]], "model" => "nomic-embed-text"})

      assert {:ok, [[0.1, 0.2], [0.3, 0.4]]} = Ollama.embed(["a", "b"], stub_opts())
    end

    test "normalises integers to floats, because JSON decodes an exact 0 as one" do
      stub_json(%{"embeddings" => [[0, 1, 0.5]]})

      assert {:ok, [vector]} = Ollama.embed(["a"], stub_opts())
      assert Enum.all?(vector, &is_float/1)
      assert vector == [0.0, 1.0, 0.5]
    end

    test "a batch that comes back short is malformed, not a partial success" do
      stub_json(%{"embeddings" => [[0.1, 0.2]]})

      assert {:error, {:malformed_response, _body}} = Ollama.embed(["a", "b"], stub_opts())
    end

    test "the singular `embedding` key of the deprecated endpoint is malformed" do
      stub_json(%{"embedding" => [0.1, 0.2]})

      assert {:error, {:malformed_response, _body}} = Ollama.embed(["a"], stub_opts())
    end

    test "a non-200 carries the status and the body" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => "model 'nope' not found"})
      end)

      assert {:error, {:http_error, 404, %{"error" => "model 'nope' not found"}}} =
               Ollama.embed(["a"], stub_opts())
    end

    test "a server that is not running is a transport error, not a crash" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:transport_error, %Req.TransportError{reason: :econnrefused}}} =
               Ollama.embed(["a"], stub_opts())
    end
  end

  test "dimensions/1 reports the configured width, so the migration and the runtime agree" do
    assert Ollama.dimensions(@opts) == 768
    assert Ollama.dimensions(Keyword.put(@opts, :dimensions, 1024)) == 1024
  end

  @tag :live
  test "a well-formed call round-trips against a real local Ollama" do
    config = Application.fetch_env!(:mem0, :live_embedder)

    assert {:ok, [first, second]} = Ollama.embed(["a sentence", "a different sentence"], config)
    assert length(first) == Ollama.dimensions(config)
    assert length(second) == Ollama.dimensions(config)
    assert Enum.all?(first, &is_float/1)
    assert first != second
  end

  defp capture_request(texts, opts) do
    Ollama.embed(texts, Keyword.put(opts, :req_options, adapter: Mem0.ReqEcho))

    assert_received {:req_request, request}
    request
  end

  defp capture_body(texts, opts) do
    texts
    |> capture_request(opts)
    |> Map.fetch!(:body)
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end

  defp stub_json(body), do: Req.Test.stub(__MODULE__, &Req.Test.json(&1, body))

  defp stub_opts, do: Keyword.put(@opts, :req_options, plug: {Req.Test, __MODULE__})
end
