defmodule Mem0.Ingester.DecoderTest do
  @moduledoc """
  The content shapes `Mem0.Ingester.Decoder` accepts: a bare string, a list of
  text blocks, and the non-text blocks that must contribute nothing.
  """
  use ExUnit.Case, async: true

  alias Mem0.Ingester.Decoder

  describe "decode_contents/1" do
    test "a bare string is trimmed" do
      assert Decoder.decode_contents("  hello  ") == "hello"
    end

    test "text blocks are trimmed and joined with a newline" do
      blocks = [%{"text" => " one "}, %{"text" => "two"}]

      assert Decoder.decode_contents(blocks) == "one\ntwo"
    end

    test "strings and text blocks mix in one list" do
      assert Decoder.decode_contents(["one", %{"text" => "two"}]) == "one\ntwo"
    end

    test "non-text blocks contribute nothing" do
      blocks = [
        %{"type" => "tool_result", "content" => "ok"},
        %{"text" => "kept"},
        %{"type" => "image", "source" => "data:..."}
      ]

      assert Decoder.decode_contents(blocks) == "kept"
    end

    test "a list with nothing to say decodes to the empty string" do
      assert Decoder.decode_contents([]) == ""
      assert Decoder.decode_contents([%{"type" => "tool_use"}]) == ""
    end
  end
end
