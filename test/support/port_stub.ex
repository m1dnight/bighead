defmodule Mem0.PortStub do
  @moduledoc """
  The machinery behind `Mem0.LLM.Stub` and `Mem0.Embedder.Stub`.

  A stub holds two things: what to reply with, and every request it was handed.
  Both live in an `Agent` started by the test and supervised by ExUnit, so state
  never leaks between tests and `async: true` stays true.

  The agent's pid is stored in the *starting* process's dictionary. Lookup walks
  `self()` and then `$callers`, reading each dictionary with `Process.info/2`,
  so a stub configured in the test process is still found when the call happens
  inside a `Task` the test spawned. Nothing in Phase 3 needs that; the pipeline
  in a later phase will, and discovering it then means debugging a stub instead
  of a pipeline.
  """

  @typedoc """
  What a stub should do when called.

  A canned success, a canned failure, or a function of the request and options —
  which is how a test asserts on *what was sent* while still choosing what comes
  back.
  """
  @type reply :: {:ok, term()} | {:error, term()} | (term(), keyword() -> term())

  @doc """
  Starts a stub agent under the test supervisor and registers it for this process.

  Returns the agent pid. Called from `Mem0.LLM.Stub.start!/1` and
  `Mem0.Embedder.Stub.start!/1` rather than directly.
  """
  @spec start!(atom(), reply()) :: pid()
  def start!(key, reply) do
    spec = Supervisor.child_spec({Agent, fn -> %{reply: reply, calls: []} end}, id: key)
    pid = ExUnit.Callbacks.start_supervised!(spec)
    Process.put(key, pid)
    pid
  end

  @doc "Replaces what the stub replies with, mid-test."
  @spec set(atom(), reply()) :: :ok
  def set(key, reply), do: Agent.update(agent!(key), &%{&1 | reply: reply})

  @doc """
  Records `request` and produces the configured reply.

  A function reply is called *outside* the agent: it is test code, it may be
  slow, and running it inside `Agent.get_and_update/2` would serialise every
  concurrent call behind it.
  """
  @spec call(atom(), term(), keyword()) :: term()
  def call(key, request, opts) do
    reply =
      Agent.get_and_update(agent!(key), fn state ->
        {state.reply, %{state | calls: [request | state.calls]}}
      end)

    if is_function(reply, 2), do: reply.(request, opts), else: reply
  end

  @doc "Every request the stub received, oldest first."
  @spec calls(atom()) :: [term()]
  def calls(key), do: key |> agent!() |> Agent.get(& &1.calls) |> Enum.reverse()

  defp agent!(key) do
    case find(key, [self() | Process.get(:"$callers", [])]) do
      nil ->
        raise """
        No #{inspect(key)} stub is running for #{inspect(self())}.

        Start one in the test (or in a setup block) before the code under test
        calls the port:

            Mem0.LLM.Stub.start!(reply: {:ok, %{content: "…"}})
        """

      pid ->
        pid
    end
  end

  defp find(_key, []), do: nil

  defp find(key, [pid | rest]) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, key) || find(key, rest)
      nil -> find(key, rest)
    end
  end
end
