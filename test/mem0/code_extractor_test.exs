defmodule Mem0.CodeExtractorTest do
  @moduledoc """
  Extraction through the stubbed LLM: what gets asked and what comes back.
  The extractor is pure over the diff it is handed — no database, no side
  effects. No test here spends money.
  """
  use ExUnit.Case, async: true

  alias Mem0.CodeExtractor
  alias Mem0.CodeExtractor.Prompt
  alias Mem0.LLM
  alias Mem0.Store.Diff

  @diff %Diff{
    file: "lib/foo.ex",
    diff: """
    @@ -1,2 +1,1 @@
    -list |> Enum.map(&f/1) |> List.flatten()
    +Enum.flat_map(list, &f/1)
    """
  }

  setup do
    LLM.Stub.start!()
    :ok
  end

  describe "extract_guidelines/1" do
    test "returns the extracted guidelines" do
      set_guidelines_reply(["Use Enum.flat_map/2 rather than map |> flatten"])

      assert {:ok, ["Use Enum.flat_map/2 rather than map |> flatten"]} =
               CodeExtractor.extract_guidelines(@diff)
    end

    test "asks with the extraction prompt, the schema and the diff" do
      set_guidelines_reply([])

      assert {:ok, []} = CodeExtractor.extract_guidelines(@diff)

      assert [request] = LLM.Stub.calls()
      assert request.system == Prompt.system_prompt()
      assert request.schema["required"] == ["guidelines"]

      assert [%{role: :user, content: prompt}] = request.messages
      assert prompt =~ "lib/foo.ex"
      assert prompt =~ "+Enum.flat_map(list, &f/1)"
    end

    test "a blank diff is zero guidelines, not an error" do
      assert {:ok, []} = CodeExtractor.extract_guidelines(%Diff{file: "lib/foo.ex", diff: "  \n"})
      assert LLM.Stub.calls() == []
    end

    test "an LLM failure comes back as that failure" do
      LLM.Stub.set({:error, {:http_error, 429, %{"error" => "rate_limit_error"}}})

      assert {:error, {:http_error, 429, _body}} = CodeExtractor.extract_guidelines(@diff)
    end

    test "a reply that is not the schema's shape is an error" do
      LLM.Stub.set({:ok, LLM.Stub.response("not json at all")})

      assert {:error, :invalid_response_from_llm} = CodeExtractor.extract_guidelines(@diff)
    end
  end

  defp set_guidelines_reply(guidelines) do
    LLM.Stub.set({:ok, LLM.Stub.response(Jason.encode!(%{"guidelines" => guidelines}))})
  end
end
