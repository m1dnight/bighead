defmodule Mem0.PostgrexTypesTest do
  @moduledoc """
  Wiring check for `Mem0.PostgrexTypes`. Runs through `Mem0.DataCase` rather than
  a bare `Repo.query/2` so it exercises the sandbox path every later test uses.
  """
  use Mem0.DataCase, async: true

  test "vector type round-trips through the repo" do
    v = Pgvector.new([1.0, 2.0, 3.0])
    assert {:ok, %{rows: [[^v]]}} = Repo.query("SELECT $1::vector", [v])
  end

  # Guards the `Pgvector.extensions()` call in lib/mem0/postgrex_types.ex.
  # Listing only `Pgvector.Extensions.Vector` there compiles and works, then
  # fails at runtime the moment a halfvec column appears — and halfvec is the
  # standard choice above pgvector's 2000-dimension index ceiling.
  test "halfvec type round-trips through the repo" do
    v = Pgvector.HalfVector.new([1.0, 2.0, 3.0])
    assert {:ok, %{rows: [[^v]]}} = Repo.query("SELECT $1::halfvec", [v])
  end

  test "pg_trgm and unaccent are installed" do
    assert {:ok, %{rows: [[true]]}} =
             Repo.query("SELECT count(*) = 3 FROM pg_extension WHERE extname = ANY($1)", [
               ["vector", "pg_trgm", "unaccent"]
             ])
  end
end
