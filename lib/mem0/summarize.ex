defmodule Mem0.Summarize do
  @moduledoc """
  Creates a summary `S` of a list of messages, and keeps the stored `S` of a
  scope level with that scope's stored messages.

  Summaries allow the LLM to extract more relevant facts for a conversation.

  Two jobs, one impurity apart. `regenerate/2` is the LLM boundary: history
  in, summary out, no store in sight. `refresh/2` is the composition the
  `Stop` pulse drives — read how far the stored `S` has fallen behind, and
  only when `Mem0.Core.Summary.stale?/2` says so, regenerate over the whole
  history and store what came back. `refresh_async/2` is `refresh/2` on a
  supervised task, so the hook route that triggers it answers before any LLM
  work starts.
  """

  alias Mem0.Core.Message
  alias Mem0.Core.Scope
  alias Mem0.Core.Summary
  alias Mem0.LLM
  alias Mem0.Messages
  alias Mem0.Summaries
  alias Mem0.Summarize.TaskSupervisor

  @task_supervisor TaskSupervisor

  @doc """
  Generates a summary for a given list of messages.
  """
  @spec regenerate([Message.t()], keyword()) :: {:ok, Summary.t()} | {:error, term()}
  def regenerate(messages, opts \\ [])

  def regenerate([], _opts) do
    {:error, :no_messages}
  end

  def regenerate([%Message{scope: scope} | _rest] = messages, opts) do
    generated_at = DateTime.utc_now()
    %Message{seq: through_seq} = Enum.max_by(messages, & &1.seq)

    # create a request for the LLM module to process.
    # This contains the messages, the system prompt and the schema.
    request = Summary.request(messages)

    with {:ok, response} <- LLM.complete(request, opts) do
      Summary.decode(response.content, scope, generated_at, through_seq)
    end
  end

  @doc """
  Given a scope, refreshes the summary for this scope.

  A summary is only generated in case any of the following is true:

   - There is no previous summary and there are more than 10 messages.

   - There is a previous summary, but there are more than 10 new messages since
     it was created.

  """
  @spec refresh(Scope.t(), keyword()) :: :fresh | {:ok, Summary.t()} | {:error, term()}
  def refresh(%Scope{} = scope, opts \\ []) do
    through_seq =
      scope
      |> Summaries.latest()
      |> through_seq()

    scope
    |> Messages.count_since(through_seq)
    |> Summary.stale?()
    |> maybe_regenerate(scope, opts)
  end

  @doc """
  `refresh/2` on a supervised task, so the caller answers immediately.

  Always return `:ok` so the caller can continue without blocking.
  """
  @spec refresh_async(Scope.t(), keyword()) :: :ok
  def refresh_async(%Scope{} = scope, opts \\ []) do
    {:ok, _pid} =
      Task.Supervisor.start_child(@task_supervisor, fn ->
        measured_refresh(scope, opts)
      end)

    :ok
  end

  # A missing summary has read nothing: no watermark, so every stored message
  # counts as pending.
  defp through_seq(nil), do: nil
  defp through_seq(%Summary{through_seq: seq}), do: seq

  defp maybe_regenerate(false = _stale, _scope, _opts), do: :fresh

  defp maybe_regenerate(true = _stale, scope, opts) do
    with {:ok, summary} <- scope |> Messages.for_run() |> regenerate(opts),
         :ok <- Summaries.put(summary) do
      {:ok, summary}
    end
  end

  defp measured_refresh(scope, opts) do
    {notify_pid, opts} = Keyword.pop(opts, :notify_pid)
    {duration, result} = :timer.tc(fn -> refresh(scope, opts) end)

    :telemetry.execute(
      [:mem0, :summarize, :refresh],
      %{duration: duration},
      %{
        outcome: outcome(result),
        user_id: scope.user_id,
        app_id: scope.app_id,
        run_id: scope.run_id
      }
    )

    if notify_pid, do: send(notify_pid, {:refreshed, scope, result})
  end

  defp outcome(:fresh), do: :fresh
  defp outcome({:ok, %Summary{}}), do: :regenerated
  defp outcome({:error, _reason}), do: :error
end
