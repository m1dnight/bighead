defmodule Mem0Web.DiffApiSpec do
  @moduledoc """
  OpenAPI operations for `Mem0Web.DiffController`. The controller delegates
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
    Accepts a code diff for one file and stores it. Posting the same payload
    twice is safe — the store dedups on file and diff text, and the reply
    carries the existing row's id.
    """,
    request_body:
      {"The diff to store", "application/json",
       %Schema{
         type: :object,
         required: [:file, :diff],
         properties: %{
           file: %Schema{type: :string, description: "Path of the file the diff applies to"},
           diff: %Schema{type: :string, description: "The diff text"}
         },
         example: %{"file" => "lib/foo.ex", "diff" => "@@ -1 +1 @@..."}
       }, required: true},
    responses: [
      ok:
        {"The diff was stored (or already existed)", "application/json",
         %Schema{
           type: :object,
           required: [:id, :file],
           properties: %{
             id: %Schema{type: :integer, description: "Id of the stored row"},
             file: %Schema{type: :string, description: "Path of the file the diff applies to"}
           },
           example: %{"id" => 7, "file" => "lib/foo.ex"}
         }},
      unprocessable_entity:
        {"The payload is not the expected shape — missing, non-string, or blank fields",
         "application/json",
         %Schema{
           type: :object,
           required: [:error],
           properties: %{error: %Schema{type: :string}},
           example: %{"error" => ~s(expected {"file": <path>, "diff": <diff text>})}
         }}
    ]
  )
end
