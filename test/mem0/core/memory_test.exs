defmodule Mem0.Core.MemoryTest do
  @moduledoc """
  The four timestamps and the provenance list are the parts of `Memory` that are
  easy to get subtly wrong, so they are what is tested here.
  """
  use ExUnit.Case, async: true
  use Mem0.CoreFixtures

  describe "from_fact/3" do
    test "copies the fact through and equates the two timestamps" do
      fact = fact(content: "User lives in San Francisco", extracted_at: at(10))

      memory = Memory.from_fact("mem-1", fact, at(11))

      assert %Memory{id: "mem-1", content: "User lives in San Francisco"} = memory
      assert memory.extracted_at == at(10)
      assert memory.created_at == at(11)
      assert memory.updated_at == memory.created_at
    end

    test "carries a nil event_time through as nil rather than as the utterance time" do
      memory = Memory.from_fact("mem-1", fact(event_time: nil), at(11))

      assert is_nil(memory.event_time)
    end
  end

  describe "apply_update/3" do
    test "keeps the id and replaces the content" do
      memory = memory(id: "mem-1", content: "User lives in SF")
      fact = fact(content: "User lives in San Francisco, in the Mission")

      updated = Memory.apply_update(memory, fact, at(99))

      assert %Memory{id: "mem-1", content: "User lives in San Francisco, in the Mission"} =
               updated
    end

    test "moves updated_at without disturbing created_at" do
      memory = memory(created_at: at(10), updated_at: at(10))

      updated = Memory.apply_update(memory, fact(), at(99))

      assert updated.created_at == at(10)
      assert updated.updated_at == at(99)
    end

    test "takes extracted_at from the fact, so it can outrun created_at" do
      memory = memory(created_at: at(10), extracted_at: at(10))

      updated = Memory.apply_update(memory, fact(extracted_at: at(50)), at(99))

      assert updated.extracted_at == at(50)
      assert :gt == DateTime.compare(updated.extracted_at, updated.created_at)
    end

    test "accumulates provenance rather than replacing it" do
      memory = memory(source_message_ids: ["msg-2", "msg-3"])

      updated = Memory.apply_update(memory, fact(source_message_ids: ["msg-8"]), at(99))

      assert updated.source_message_ids == ["msg-2", "msg-3", "msg-8"]
    end

    test "does not repeat a message id already recorded" do
      memory = memory(source_message_ids: ["msg-2", "msg-3"])

      updated = Memory.apply_update(memory, fact(source_message_ids: ["msg-3"]), at(99))

      assert updated.source_message_ids == ["msg-2", "msg-3"]
    end
  end
end
