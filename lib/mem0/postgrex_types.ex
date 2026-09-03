# Defines the Postgrex types module used by Bighead.Repo, extended with pgvector's
# extensions so that `vector`, `halfvec` and `sparsevec` columns encode/decode.
#
# This file intentionally has no `defmodule` — `Postgrex.Types.define/3` defines
# `Bighead.PostgrexTypes` as a compile-time side effect. That is the documented
# pattern; the .beam is produced normally.
Postgrex.Types.define(
  Bighead.PostgrexTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
