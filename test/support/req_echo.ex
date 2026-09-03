defmodule Bighead.ReqEcho do
  @moduledoc """
  A `Req` adapter that hands the fully-built request back to the caller.

  `Req.Test` answers a request; this inspects one. It is the only place a
  request-level option such as `receive_timeout` is still visible — a `Plug`
  sees what came off the socket, not the configuration that shaped it. Set it
  with `req_options: [adapter: Bighead.ReqEcho]` and read the message:

      assert_received {:req_request, request}
      assert request.options.receive_timeout == to_timeout(minute: 2)

  Req runs the adapter in the calling process, so the message lands in the test's
  own mailbox.
  """

  @doc "Sends `{:req_request, request}` to the caller and answers an empty 200."
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t()}
  def run(request) do
    send(self(), {:req_request, request})
    {request, %Req.Response{status: 200, body: %{}}}
  end
end
