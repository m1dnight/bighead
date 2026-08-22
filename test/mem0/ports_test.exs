defmodule Mem0.PortsTest do
  @moduledoc """
  The stub-backed contract of both ports.

  This is the file that has to keep passing with no `.env`, no API key and no
  Ollama running — everything Phases 4 onwards build sits on top of what it
  asserts.
  """
  use ExUnit.Case, async: true

  alias Mem0.Embedder
  alias Mem0.LLM

  describe "Mem0.LLM through its stub" do
    setup do
      LLM.Stub.start!()
      :ok
    end

    test "the test environment is wired to the stub, not to a live provider" do
      assert LLM.adapter() == LLM.Stub
    end

    test "a canned success comes back as a response" do
      LLM.Stub.set({:ok, LLM.Stub.response("a fact")})

      assert {:ok, %{content: "a fact", model: "stub-model", usage: usage}} =
               LLM.complete(%{messages: [%{role: :user, content: "hi"}]})

      assert %{input_tokens: 0, output_tokens: 0} = usage
    end

    for reason <- [
          {:refusal, "cyber"},
          {:refusal, nil},
          {:http_error, 429, %{"error" => "rate_limit_error"}},
          {:transport_error, %Req.TransportError{reason: :timeout}},
          {:malformed_response, %{"hello" => "world"}}
        ] do
      test "a canned #{inspect(reason)} comes back as that error" do
        LLM.Stub.set({:error, unquote(Macro.escape(reason))})

        assert {:error, unquote(Macro.escape(reason))} =
                 LLM.complete(%{messages: [%{role: :user, content: "hi"}]})
      end
    end

    test "records what was sent, so a test can assert on the request without a network" do
      LLM.complete(%{messages: [%{role: :user, content: "one"}], system: "be terse"})
      LLM.complete(%{messages: [%{role: :user, content: "two"}], schema: %{"type" => "object"}})

      assert [first, second] = LLM.Stub.calls()
      assert first.system == "be terse"
      assert first.messages == [%{role: :user, content: "one"}]
      assert second.schema == %{"type" => "object"}
      refute Map.has_key?(second, :system)
    end

    test "a function reply sees the request and the merged configuration" do
      LLM.Stub.set(fn request, opts ->
        {:ok, LLM.Stub.response("#{opts[:model]}:#{hd(request.messages).content}")}
      end)

      assert {:ok, %{content: "stub-model:hi"}} =
               LLM.complete(%{messages: [%{role: :user, content: "hi"}]})
    end

    test "caller options win over the configured ones" do
      LLM.Stub.set(fn _request, opts -> {:ok, LLM.Stub.response(opts[:model])} end)

      assert {:ok, %{content: "override"}} =
               LLM.complete(%{messages: []}, model: "override")
    end

    test "is found from a task the test spawned, not only from the test itself" do
      LLM.Stub.set({:ok, LLM.Stub.response("from a task")})

      task = Task.async(fn -> LLM.complete(%{messages: [%{role: :user, content: "hi"}]}) end)

      assert {:ok, %{content: "from a task"}} = Task.await(task)
      assert [%{messages: [%{content: "hi"}]}] = LLM.Stub.calls()
    end
  end

  describe "Mem0.Embedder through its stub" do
    setup do
      Embedder.Stub.start!()
      :ok
    end

    test "the test environment is wired to the stub, not to a live provider" do
      assert Embedder.adapter() == Embedder.Stub
    end

    test "returns one vector per text, at the configured width" do
      assert {:ok, [first, second]} = Embedder.embed(["a", "b"])
      assert length(first) == Embedder.dimensions()
      assert length(second) == Embedder.dimensions()
      assert Enum.all?(first, &is_float/1)
    end

    test "an empty batch embeds to an empty list" do
      assert {:ok, []} = Embedder.embed([])
    end

    test "equal texts embed equally and different texts do not" do
      assert {:ok, [a, b, a_again]} = Embedder.embed(["a", "b", "a"])

      assert a == a_again
      assert a != b
    end

    test "a canned error comes back as that error" do
      Embedder.Stub.set({:error, {:transport_error, %Req.TransportError{reason: :econnrefused}}})

      assert {:error, {:transport_error, %Req.TransportError{reason: :econnrefused}}} =
               Embedder.embed(["a"])
    end

    test "records what was sent" do
      Embedder.embed(["one", "two"])
      Embedder.embed(["three"])

      assert Embedder.Stub.calls() == [["one", "two"], ["three"]]
    end

    test "declares the configured width without inventing vectors of the wrong size" do
      assert Embedder.dimensions() == 768
      assert Embedder.dimensions(dimensions: 384) == 384

      assert {:ok, [vector]} = Embedder.embed(["a"], dimensions: 384)
      assert length(vector) == 384
    end
  end

  test "a port with no stub running says so, rather than failing somewhere else" do
    assert_raise RuntimeError, ~r/No :mem0_llm_stub stub is running/, fn ->
      LLM.complete(%{messages: []})
    end
  end
end
