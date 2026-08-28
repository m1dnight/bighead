defmodule Mem0.Summaries.Row do
  @moduledoc """
  The `summaries` table, and the translation between it and
  `Mem0.Core.Summary`.
  """

  use Ecto.Schema

  alias Mem0.Core.Scope
  alias Mem0.Core.Summary

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: String.t(),
          app_id: String.t() | nil,
          run_id: String.t() | nil,
          text: String.t(),
          through_seq: non_neg_integer(),
          generated_at: DateTime.t(),
          inserted_at: DateTime.t() | nil
        }

  schema "summaries" do
    field :user_id, :string
    field :app_id, :string
    field :run_id, :string
    field :text, :string
    field :through_seq, :integer
    field :generated_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Creates a `Row` struct that's insertable into the table, based on a given
  `Summary`.
  """
  @spec from_summary(Summary.t()) :: t()
  def from_summary(%Summary{} = summary) do
    %__MODULE__{
      user_id: summary.scope.user_id,
      app_id: summary.scope.app_id,
      run_id: summary.scope.run_id,
      text: summary.text,
      through_seq: summary.through_seq,
      generated_at: summary.generated_at
    }
  end

  @doc """
  Converts a `Row` back into a `Summary` struct.
  """
  @spec to_summary(t()) :: Summary.t()
  def to_summary(%__MODULE__{} = row) do
    Summary.new(
      scope: Scope.new(user_id: row.user_id, app_id: row.app_id, run_id: row.run_id),
      text: row.text,
      generated_at: row.generated_at,
      through_seq: row.through_seq
    )
  end
end
