defmodule Bighead.LLM.Stub do
  @moduledoc """
  `Bighead.LLM` that answers from a canned reply and records what it was asked.

  Lives in `test/support/` rather than `lib/`: it is test infrastructure, and
  putting it in `lib/` ships it. `config/test.exs` points `:llm` here, so every
  test gets it by default and no test suite can silently reach a live provider.

      test "sends the system prompt" do
        Bighead.LLM.Stub.start!(reply: {:ok, response("ok")})

        assert {:ok, %{content: "ok"}} =
                 Bighead.LLM.complete(%{messages: [%{role: :user, content: "hi"}], system: "be terse"})

        assert [%{system: "be terse"}] = Bighead.LLM.Stub.calls()
      end
  """

  @behaviour Bighead.LLM

  alias Bighead.PortStub

  @key :bighead_llm_stub

  @doc """
  A well-formed `t:Bighead.LLM.response/0`, for tests that only care about the text.
  """
  @spec response(String.t()) :: Bighead.LLM.response()
  def response(content) do
    %{content: content, model: "stub-model", usage: %{input_tokens: 0, output_tokens: 0}}
  end

  @doc """
  Starts the stub for this test.

  `:reply` is a `{:ok, response}`, an `{:error, reason}`, or a two-argument
  function of the request and the options. Defaults to a bland success, so a
  test that only needs the port to not explode passes no options at all.
  """
  @spec start!(keyword()) :: pid()
  def start!(opts \\ []) do
    PortStub.start!(@key, Keyword.get(opts, :reply, {:ok, response("")}))
  end

  @doc "Replaces the reply mid-test."
  @spec set(PortStub.reply()) :: :ok
  def set(reply), do: PortStub.set(@key, reply)

  @doc "Every request the stub received, oldest first."
  @spec calls() :: [Bighead.LLM.request()]
  def calls, do: PortStub.calls(@key)

  @impl Bighead.LLM
  def complete(request, opts), do: PortStub.call(@key, request, opts)
end
