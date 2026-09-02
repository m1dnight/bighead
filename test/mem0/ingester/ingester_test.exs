defmodule Mem0.IngesterTest.StubIngester do
  @moduledoc """
  A minimal `Mem0.Ingester` so the generic pipeline can be tested apart from
  any real transcript format: entries opt out via `"skip"`, fail to parse via
  `"boom"`, and the scope comes from the first entry carrying `"scope"`.
  """

  @behaviour Mem0.Ingester

  @timestamp ~U[2026-08-24 09:00:00.000000Z]

  @impl true
  def skip_entry?(entry), do: Map.get(entry, "skip", false)

  @impl true
  def parse_entry(%{"boom" => true}), do: {:error, :boom}

  def parse_entry(entry) do
    {:ok,
     %{
       id: Map.get(entry, "id"),
       role: Map.get(entry, "role", "user"),
       content: Map.get(entry, "content", ""),
       timestamp: @timestamp
     }}
  end

  @impl true
  def scope(entries) do
    case Enum.find(entries, &Map.has_key?(&1, "scope")) do
      %{"scope" => scope} -> {:ok, %{project: scope, session: scope}}
      nil -> {:error, :no_scope}
    end
  end
end

defmodule Mem0.IngesterTest do
  @moduledoc """
  The contract of `Mem0.Ingester.decode_transcript/2`: line decoding, skip
  filtering, empty-message dropping and error propagation, driven through a
  stub ingester so no real format is involved.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mem0.Ingester
  alias Mem0.IngesterTest.StubIngester

  describe "decode_transcript/2" do
    test "returns the scope and the messages, in file order" do
      transcript =
        transcript([
          %{"scope" => "s", "id" => "1", "content" => "first"},
          %{"id" => "2", "content" => "second"}
        ])

      assert {:ok, scope, [first, second]} =
               Ingester.decode_transcript(transcript, StubIngester)

      assert scope == %{project: "s", session: "s"}
      assert %{id: "1", content: "first"} = first
      assert %{id: "2", content: "second"} = second
    end

    test "skipped entries produce no message and no error" do
      transcript =
        transcript([
          %{"scope" => "s", "content" => "kept"},
          %{"skip" => true, "content" => "dropped"}
        ])

      assert {:ok, _scope, [%{content: "kept"}]} =
               Ingester.decode_transcript(transcript, StubIngester)
    end

    test "a message that parses to empty content is dropped" do
      transcript = transcript([%{"scope" => "s", "content" => ""}])

      assert {:ok, _scope, []} = Ingester.decode_transcript(transcript, StubIngester)
    end

    test "a line that does not decode fails the transcript" do
      transcript =
        Enum.join([Jason.encode!(%{"scope" => "s"}), "{not json", "{"], "\n")

      assert {:error, :decode_failed} =
               Ingester.decode_transcript(transcript, StubIngester)
    end

    test "a parse failure drops the entry, the rest imports" do
      transcript = transcript([%{"scope" => "s", "content" => "kept"}, %{"boom" => true}])

      log =
        capture_log(fn ->
          assert {:ok, _scope, [%{content: "kept"}]} =
                   Ingester.decode_transcript(transcript, StubIngester)
        end)

      assert log =~ "Failed to import some messages"
    end

    test "a scope failure fails the transcript before any parsing" do
      transcript = transcript([%{"content" => "no scope anywhere"}])

      assert {:error, :no_scope} = Ingester.decode_transcript(transcript, StubIngester)
    end
  end

  defp transcript(entries), do: Enum.map_join(entries, "\n", &Jason.encode!/1)
end
