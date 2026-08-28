defmodule Mem0.ExtractionState.Row do
  @moduledoc """
  The `extraction_state` table: one row per scope, updated in place.

  Update-in-place is a first for this codebase and is fine here: this is
  bookkeeping about the pipeline, not domain data about the user — nothing
  the append-mostly rule protects (audit, ordering, supersession history)
  lives in this table. What the mutable row gives up is pulse history, which
  telemetry already carries live.
  """

  use Ecto.Schema

  alias Mem0.Core.Scope

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: String.t(),
          app_id: String.t() | nil,
          run_id: String.t() | nil,
          through_seq: non_neg_integer(),
          pulsed_at: DateTime.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "extraction_state" do
    field :user_id, :string
    field :app_id, :string
    field :run_id, :string
    field :through_seq, :integer
    field :pulsed_at, :utc_datetime_usec

    # Ecto bookkeeping, and this table being bookkeeping itself, that is
    # honest rather than redundant.
    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The cursor row a pulse writes: `scope` as the identity, `through_seq` as the
  watermark, `pulsed_at` as the pulse's one instant.
  """
  @spec from_scope(Scope.t(), non_neg_integer(), DateTime.t()) :: t()
  def from_scope(%Scope{} = scope, through_seq, %DateTime{} = pulsed_at) do
    %__MODULE__{
      user_id: scope.user_id,
      app_id: scope.app_id,
      run_id: scope.run_id,
      through_seq: through_seq,
      pulsed_at: pulsed_at
    }
  end
end
