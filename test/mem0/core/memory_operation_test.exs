defmodule Mem0.Core.MemoryOperationTest do
  @moduledoc """
  `parse/4` is the only function in the core that reads input the core did not
  produce, so most of what is below is malformed model output.
  """
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  doctest MemoryOperation

  setup do
    %{
      fact: fact(content: "User lives in San Francisco, in the Mission"),
      candidates: [memory(id: "mem-1"), memory(id: "mem-2", content: "User likes tea")]
    }
  end

  describe "request/2" do
    test "presents the fact and the candidates as ordinals, contents only", %{
      fact: fact,
      candidates: candidates
    } do
      request = MemoryOperation.request(fact, candidates)

      assert [%{role: :user, content: content}] = request.messages
      assert content =~ "# Candidate fact\nUser lives in San Francisco, in the Mission"
      assert content =~ "1. User lives in San Francisco"
      assert content =~ "2. User likes tea"
    end

    test "ids never reach the model", %{fact: fact, candidates: candidates} do
      request = MemoryOperation.request(fact, candidates)

      assert [%{content: content}] = request.messages
      refute content =~ "mem-1"
      refute content =~ "mem-2"
    end

    test "carries the cascade as the system prompt and pins the reply shape", %{
      fact: fact,
      candidates: candidates
    } do
      request = MemoryOperation.request(fact, candidates)

      assert request.system == MemoryOperation.system_prompt()
      assert request.schema["required"] == ["event", "reason"]
      assert request.schema["additionalProperties"] == false
      assert request.schema["properties"]["event"]["enum"] == ["ADD", "UPDATE", "DELETE", "NOOP"]
    end

    test "an empty candidate list is an explicitly empty section, not a missing one", %{
      fact: fact
    } do
      assert [%{content: content}] = MemoryOperation.request(fact, []).messages
      assert content =~ "# Retrieved memories\n(none)"
    end
  end

  describe "decode/4" do
    test "builds a Decision carrying the reason, considered ids in order, and the instant", %{
      fact: fact,
      candidates: candidates
    } do
      reply = ~s({"event": "UPDATE", "id": 2, "reason": "Adds The Neighbourhood."})

      assert {:ok, decision} = MemoryOperation.decode(reply, fact, candidates, at(11))
      assert decision.operation == {:update, "mem-2", fact}
      assert decision.reason == "Adds The Neighbourhood."
      assert decision.considered_ids == ["mem-1", "mem-2"]
      assert decision.decided_at == at(11)
    end

    test "the reason survives verbatim, not sanitized", %{fact: fact, candidates: candidates} do
      reply = ~s({"event": "ADD", "reason": "  Nothing Covers WHERE the user lives.  "})

      assert {:ok, decision} = MemoryOperation.decode(reply, fact, candidates, at(0))
      assert decision.reason == "  Nothing Covers WHERE the user lives.  "
    end

    test "an empty candidate list decodes ADD and NOOP", %{fact: fact} do
      add = ~s({"event": "ADD", "reason": "New information."})
      noop = ~s({"event": "NOOP", "reason": "Nothing to do."})

      assert {:ok, %Decision{operation: {:add, ^fact}, considered_ids: []}} =
               MemoryOperation.decode(add, fact, [], at(0))

      assert {:ok, %Decision{operation: :noop}} = MemoryOperation.decode(noop, fact, [], at(0))
    end

    test "an empty candidate list refuses any ordinal", %{fact: fact} do
      reply = ~s({"event": "UPDATE", "id": 1, "reason": "Augments memory 1."})

      assert {:error, {:ordinal_out_of_range, 1}} = MemoryOperation.decode(reply, fact, [], at(0))
    end

    test "the information-gain guard degrades through decode too", %{candidates: candidates} do
      no_gain = fact(content: "User likes tea")
      reply = ~s({"event": "UPDATE", "id": 2, "reason": "Same fact restated."})

      assert {:ok, %Decision{operation: :noop}} =
               MemoryOperation.decode(reply, no_gain, candidates, at(0))
    end

    test "a reply that is not JSON is malformed output, not a raise", %{
      fact: fact,
      candidates: candidates
    } do
      assert {:error, {:malformed_output, "Sure! I would ADD this."}} =
               MemoryOperation.decode("Sure! I would ADD this.", fact, candidates, at(0))
    end

    test "a parse failure surfaces as its own reason", %{fact: fact, candidates: candidates} do
      reply = ~s({"event": "MERGE", "reason": "Blend them."})

      assert {:error, {:unknown_event, "merge"}} =
               MemoryOperation.decode(reply, fact, candidates, at(0))
    end

    test "a reply missing its reason still decodes, with an empty one", %{
      fact: fact,
      candidates: candidates
    } do
      assert {:ok, %Decision{reason: ""}} =
               MemoryOperation.decode(~s({"event": "NOOP"}), fact, candidates, at(0))
    end
  end

  describe "parse/4 — the happy cascade" do
    test "ADD carries the extracted fact and no id", %{fact: fact, candidates: candidates} do
      assert {:ok, {:add, ^fact}} =
               MemoryOperation.parse(%{"event" => "ADD"}, fact, candidates)
    end

    test "UPDATE maps the ordinal back to an id", %{fact: fact, candidates: candidates} do
      assert {:ok, {:update, "mem-2", ^fact}} =
               MemoryOperation.parse(%{"event" => "UPDATE", "id" => 2}, fact, candidates)
    end

    test "DELETE maps the ordinal back to an id", %{fact: fact, candidates: candidates} do
      assert {:ok, {:delete, "mem-1"}} =
               MemoryOperation.parse(%{"event" => "DELETE", "id" => 1}, fact, candidates)
    end

    test "NONE is a noop", %{fact: fact, candidates: candidates} do
      assert {:ok, :noop} = MemoryOperation.parse(%{"event" => "NONE"}, fact, candidates)
    end

    test "accepts the lowercase and digit-string forms models actually emit", %{
      fact: fact,
      candidates: candidates
    } do
      assert {:ok, {:update, "mem-2", ^fact}} =
               MemoryOperation.parse(%{"event" => " update ", "id" => "2"}, fact, candidates)
    end
  end

  describe "parse/4 — malformed model output" do
    test "an ordinal past the end of the candidate list", %{fact: fact, candidates: candidates} do
      assert {:error, {:ordinal_out_of_range, 3}} =
               MemoryOperation.parse(%{"event" => "UPDATE", "id" => 3}, fact, candidates)
    end

    test "an ordinal below one", %{fact: fact, candidates: candidates} do
      assert {:error, {:ordinal_out_of_range, 0}} =
               MemoryOperation.parse(%{"event" => "DELETE", "id" => 0}, fact, candidates)
    end

    test "an ordinal that is not a number at all", %{fact: fact, candidates: candidates} do
      assert {:error, {:malformed_ordinal, "the second one"}} =
               MemoryOperation.parse(
                 %{"event" => "UPDATE", "id" => "the second one"},
                 fact,
                 candidates
               )
    end

    test "no ordinal where one was needed", %{fact: fact, candidates: candidates} do
      assert {:error, :missing_ordinal} =
               MemoryOperation.parse(%{"event" => "UPDATE"}, fact, candidates)
    end

    test "no event key", %{fact: fact, candidates: candidates} do
      assert {:error, :missing_event} = MemoryOperation.parse(%{"id" => 1}, fact, candidates)
    end

    test "an operation name nobody defined", %{fact: fact, candidates: candidates} do
      assert {:error, {:unknown_event, "merge"}} =
               MemoryOperation.parse(%{"event" => "MERGE"}, fact, candidates)
    end

    test "output that is not a map", %{fact: fact, candidates: candidates} do
      assert {:error, {:malformed_output, "ADD"}} =
               MemoryOperation.parse("ADD", fact, candidates)
    end

    test "never raises, whatever it is handed", %{fact: fact, candidates: candidates} do
      for output <- [nil, [], "", %{}, %{"event" => 7}, %{"event" => "UPDATE", "id" => %{}}] do
        assert {:error, _reason} = MemoryOperation.parse(output, fact, candidates)
      end
    end
  end

  describe "the information-gain guard" do
    test "an UPDATE that adds nothing degrades to a noop", %{candidates: candidates} do
      no_gain = fact(content: "User likes tea")

      assert {:ok, :noop} =
               MemoryOperation.parse(%{"event" => "UPDATE", "id" => 2}, no_gain, candidates)
    end

    test "an UPDATE that adds something survives", %{fact: fact, candidates: candidates} do
      assert {:ok, {:update, "mem-2", ^fact}} =
               MemoryOperation.parse(%{"event" => "UPDATE", "id" => 2}, fact, candidates)
    end

    test "the predicate is injectable", %{candidates: candidates} do
      no_gain = fact(content: "User likes tea")
      always = fn _fact, _memory -> true end

      assert {:ok, {:update, "mem-2", ^no_gain}} =
               MemoryOperation.parse(
                 %{"event" => "UPDATE", "id" => 2},
                 no_gain,
                 candidates,
                 always
               )
    end

    test "ADD, DELETE and NOOP pass through the guard untouched", %{
      fact: fact,
      candidates: candidates
    } do
      never = fn _fact, _memory -> false end

      for operation <- [{:add, fact}, {:delete, "mem-1"}, :noop] do
        assert operation == MemoryOperation.enforce_information_gain(operation, candidates, never)
      end
    end

    test "an UPDATE naming an id outside the candidates is left alone", %{fact: fact} do
      operation = {:update, "mem-elsewhere", fact}

      assert operation == MemoryOperation.enforce_information_gain(operation, [], &always_false/2)
    end
  end

  describe "richer?/2" do
    test "counts words, strictly" do
      assert MemoryOperation.richer?(fact(content: "a b c"), memory(content: "a b"))
      refute MemoryOperation.richer?(fact(content: "a b"), memory(content: "a b"))
      refute MemoryOperation.richer?(fact(content: "a"), memory(content: "a b"))
    end

    test "the documented cost: a same-length correction is not richer" do
      refute MemoryOperation.richer?(
               fact(content: "User lives in NY"),
               memory(content: "User lives in SF")
             )
    end
  end

  defp always_false(_fact, _memory), do: false
end
