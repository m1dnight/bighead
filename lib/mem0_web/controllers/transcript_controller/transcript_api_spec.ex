defmodule Mem0Web.TranscriptApiSpec do
  @moduledoc """
  OpenAPI operations for `Mem0Web.TranscriptController`. The controller
  delegates `open_api_operation/1` here so the spec lives next to the code
  it describes without crowding it.
  """

  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema

  @error_schema %Schema{
    type: :object,
    required: [:error],
    properties: %{error: %Schema{type: :string, description: "Why the request failed"}}
  }

  tags(["transcripts"])

  operation(:create,
    operation_id: "createTranscript",
    summary: "Ingest a whole transcript file",
    description: """
    Accepts a whole Claude Code transcript file as raw JSON Lines, one JSON
    object per line. The body is read verbatim, so post it with a content
    type that is not parsed as a single JSON document
    (`application/x-ndjson`) — `Plug.Parsers` would otherwise consume the
    body before the controller sees it. Re-posting is always safe: the
    message store dedups what it has already seen and the processor's
    watermark refuses what it has already read.
    """,
    request_body: {"The transcript file content, as raw JSON Lines", "application/x-ndjson", %Schema{type: :string}, required: true},
    responses: [
      ok:
        {"The transcript was stored", "application/json",
         %Schema{
           type: :object,
           required: [:stored, :scope],
           properties: %{
             stored: %Schema{type: :integer, description: "How many messages were stored"},
             scope: %Schema{
               type: :object,
               description: "The scope the messages landed in",
               required: [:user, :project, :session],
               properties: %{
                 user: %Schema{type: :string},
                 project: %Schema{type: :string},
                 session: %Schema{type: :string}
               }
             }
           },
           example: %{
             "stored" => 42,
             "scope" => %{
               "user" => "default",
               "project" => "/Users/example/project",
               "session" => "6e6964bc-e111-441b-8978-c45a0fb29b33"
             }
           }
         }},
      bad_request: {"The request body could not be read", "application/json", @error_schema},
      request_entity_too_large: {"The transcript exceeds 50,000,000 bytes", "application/json", @error_schema},
      internal_server_error:
        {"The transcript could not be imported — not JSON Lines, or storing failed", "application/json", @error_schema}
    ]
  )
end
