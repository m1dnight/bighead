defmodule BigheadWeb.DiffApiSpec do
  @moduledoc """
  OpenAPI operations for `BigheadWeb.DiffController`. The controller delegates
  `open_api_operation/1` here so the spec lives next to the code it
  describes without crowding it.
  """

  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema

  tags(["diffs"])

  operation(:create,
    operation_id: "createDiff",
    summary: "Store one diff",
    description: """
    Accepts a code diff for one file and stores it under the scope named by
    `project` and `session` — the same `(cwd, session id)` pair a transcript
    resolves to, created on first sight. Posting the same payload twice is
    safe — the store dedups on file and diff text, and the reply carries the
    existing row's id.
    """,
    request_body:
      {"The diff to store", "application/json",
       %Schema{
         type: :object,
         required: [:file, :diff, :project, :session, :origin],
         properties: %{
           file: %Schema{type: :string, description: "Path of the file the diff applies to"},
           diff: %Schema{type: :string, description: "The diff text"},
           project: %Schema{
             type: :string,
             description: "Working directory of the session the diff happened in"
           },
           session: %Schema{type: :string, description: "Id of the session the diff happened in"},
           origin: %Schema{
             type: :string,
             enum: ["manual", "own", "requested", "agent"],
             description:
               "manual: the developer edited the agent's code by hand; " <>
                 "own: the developer edited code the agent had not touched; " <>
                 "requested: the agent changed its own code on the developer's prompt; " <>
                 "agent: the agent's own work on the developer's code"
           }
         },
         example: %{
           "file" => "lib/foo.ex",
           "diff" => "@@ -1 +1 @@...",
           "project" => "/code/widget",
           "session" => "3f0f569b-0d3c-4f6e-9a3e-2b9c1d5e7f01",
           "origin" => "manual"
         }
       }, required: true},
    responses: [
      ok:
        {"The diff was stored (or already existed)", "application/json",
         %Schema{
           type: :object,
           required: [:id, :file, :scope_id],
           properties: %{
             id: %Schema{type: :integer, description: "Id of the stored row"},
             file: %Schema{type: :string, description: "Path of the file the diff applies to"},
             scope_id: %Schema{
               type: :integer,
               description: "Id of the scope the diff is filed under"
             }
           },
           example: %{"id" => 7, "file" => "lib/foo.ex", "scope_id" => 3}
         }},
      unprocessable_entity:
        {"The payload is not the expected shape — missing, non-string, or blank fields", "application/json",
         %Schema{
           type: :object,
           required: [:error],
           properties: %{error: %Schema{type: :string}},
           example: %{
             "error" => ~s(expected {"file": <path>, "diff": <diff text>, "project": <cwd>, "session": <session id>})
           }
         }}
    ]
  )
end
