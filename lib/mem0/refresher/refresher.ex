defmodule Mem0.Refresher do
  @moduledoc """
  Runs fact extraction over whatever the ingestion side accumulated.

  The database is the queue: a scope needs work exactly when it has messages
  past its extraction watermark, so this server keeps no state of its own —
  every sweep derives its work set from `Scopes.stale/0`. It sweeps on a
  timer and can be poked after an import; either way the sweep is the same,
  so pokes for the same scope coalesce for free, and a crash loses nothing.

  One process, so extractions run one at a time: no watermark races, and at
  most one LLM call in flight.
  """

  use GenServer

  alias Mem0.Processor
  alias Mem0.Store.Scopes

  require Logger

  @tick to_timeout(minute: 1)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # ---------------------------------------------------------------------------#
  #                                API                                         #
  # ---------------------------------------------------------------------------#

  @doc """
  Asks the refresher to sweep soon.

  A cast, deliberately: the caller is a live hook request and must not wait
  behind whatever extraction is already running.
  """
  @spec poke(GenServer.server()) :: :ok
  def poke(server \\ __MODULE__) do
    GenServer.cast(server, :poke)
  end

  # ---------------------------------------------------------------------------#
  #                                Callbacks                                   #
  # ---------------------------------------------------------------------------#

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, nil}
  end

  @impl true
  def handle_cast(:poke, state) do
    sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    sweep()
    schedule_tick()
    {:noreply, state}
  end

  # A failed extraction leaves the watermark where it was, so the next sweep
  # is the retry — nothing to track here.
  @spec sweep() :: :ok
  defp sweep do
    case Processor.process_sessions() do
      {[], []} ->
        :ok

      {_success, []} ->
        :ok

      {[], _failed} ->
        Logger.error("Failed to process sessions")
        :ok

      {_success, _failed} ->
        Logger.error("Failed to process some sessions")
        :ok
    end
  end

  @spec schedule_tick() :: reference()
  defp schedule_tick do
    Process.send_after(self(), :tick, @tick)
  end
end
