defmodule Bighead.CodeExtractorTest do
  @moduledoc """
  Extraction through the stubbed LLM: what gets asked and what comes back.
  The extractor is pure over the diffs it is handed — no database, no side
  effects. No test here spends money.
  """
  use ExUnit.Case, async: true

  alias Bighead.CodeExtractor
  alias Bighead.CodeExtractor.Prompt
  alias Bighead.LLM
  alias Bighead.Store.Diff

  @foo %Diff{
    id: 2,
    file: "lib/foo.ex",
    origin: :manual,
    diff: """
    @@ -1,2 +1,1 @@
    -list |> Enum.map(&f/1) |> List.flatten()
    +Enum.flat_map(list, &f/1)
    """
  }

  @bar %Diff{
    id: 1,
    file: "lib/bar.ex",
    origin: :requested,
    diff: """
    @@ -1 +1 @@
    -IO.inspect(x)
    +Logger.debug(x)
    """
  }

  @baz %Diff{
    id: 3,
    file: "lib/baz.ex",
    origin: :agent,
    diff: """
    @@ -1 +1 @@
    -x
    +y
    """
  }

  setup do
    LLM.Stub.start!()
    :ok
  end

  describe "extract_guidelines/1" do
    test "returns the guidelines extracted from the batch" do
      set_guidelines_reply(["Use Enum.flat_map/2 rather than map |> flatten"])

      assert {:ok, ["Use Enum.flat_map/2 rather than map |> flatten"]} =
               CodeExtractor.extract_guidelines([@foo, @bar])
    end

    test "asks once, with the extraction prompt, the schema and every diff grouped by file" do
      set_guidelines_reply([])

      assert {:ok, []} = CodeExtractor.extract_guidelines([@foo, @bar])

      assert [request] = LLM.Stub.calls()
      assert request.system == Prompt.system_prompt()
      assert request.schema["required"] == ["guidelines"]

      assert [%{role: :user, content: prompt}] = request.messages
      assert prompt =~ "+Enum.flat_map(list, &f/1)"
      assert prompt =~ "+Logger.debug(x)"
      assert prompt =~ "change: manual"
      assert prompt =~ "change: requested"
      assert first_index(prompt, "lib/bar.ex") < first_index(prompt, "lib/foo.ex")
    end

    test "blank diffs are left out, and a batch of only blanks costs no call" do
      blank = %Diff{file: "lib/blank.ex", diff: "  \n"}
      set_guidelines_reply([])

      assert {:ok, []} = CodeExtractor.extract_guidelines([blank, @foo])
      assert [%{messages: [%{content: prompt}]}] = LLM.Stub.calls()
      refute prompt =~ "lib/blank.ex"

      assert {:ok, []} = CodeExtractor.extract_guidelines([blank])
      assert [_only_the_first] = LLM.Stub.calls()
    end

    test "a file with only the agent's own diffs is left out, and a batch of only those costs no call" do
      set_guidelines_reply([])

      assert {:ok, []} = CodeExtractor.extract_guidelines([@baz, @foo])
      assert [%{messages: [%{content: prompt}]}] = LLM.Stub.calls()
      refute prompt =~ "lib/baz.ex"

      assert {:ok, []} = CodeExtractor.extract_guidelines([@baz])
      assert [_only_the_first] = LLM.Stub.calls()
    end

    test "an LLM failure comes back as that failure" do
      LLM.Stub.set({:error, {:http_error, 429, %{"error" => "rate_limit_error"}}})

      assert {:error, {:http_error, 429, _body}} = CodeExtractor.extract_guidelines([@foo])
    end

    test "a reply that is not the schema's shape is an error" do
      LLM.Stub.set({:ok, LLM.Stub.response("not json at all")})

      assert {:error, :invalid_response_from_llm} = CodeExtractor.extract_guidelines([@foo])
    end
  end

  defp set_guidelines_reply(guidelines) do
    LLM.Stub.set({:ok, LLM.Stub.response(Jason.encode!(%{"guidelines" => guidelines}))})
  end

  defp first_index(string, part) do
    {index, _length} = :binary.match(string, part)
    index
  end
end
