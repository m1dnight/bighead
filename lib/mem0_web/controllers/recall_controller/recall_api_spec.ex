defmodule Mem0Web.RecallApiSpec do
  @moduledoc """
  OpenAPI operations for `Mem0Web.RecallController`. The controller
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

  tags(["recall"])

  operation(:create,
    operation_id: "recall",
    summary: "Recall the facts relevant to one prompt",
    description: """
    Returns the stored facts most relevant to a prompt, most relevant first.
    A prompt no stored fact resembles gets an empty list, not an error.
    """,
    request_body:
      {"The prompt to recall facts for", "application/json",
       %Schema{
         type: :object,
         required: [:prompt],
         properties: %{
           prompt: %Schema{type: :string, minLength: 1, description: "The user's prompt"},
           kind: %Schema{
             type: :string,
             enum: ["fact", "guideline"],
             description: "Only facts of this kind; every kind when absent"
           }
         },
         example: %{"prompt" => "what am I working on?"}
       }, required: true},
    responses: [
      ok:
        {"The recalled facts, most relevant first", "application/json",
         %Schema{
           type: :object,
           required: [:facts],
           properties: %{
             facts: %Schema{
               type: :array,
               items: %Schema{
                 type: :object,
                 required: [:id, :fact, :kind],
                 properties: %{
                   id: %Schema{type: :integer, description: "Id of the stored fact"},
                   fact: %Schema{type: :string, description: "The fact text"},
                   kind: %Schema{
                     type: :string,
                     enum: ["fact", "guideline"],
                     description: "fact from a conversation, guideline from a code edit"
                   }
                 }
               }
             }
           },
           example: %{
             "facts" => [
               %{"id" => 3, "fact" => "The user prefers plain typespecs.", "kind" => "fact"}
             ]
           }
         }},
      unprocessable_entity:
        {"The payload is not the expected shape — missing, non-string, or empty prompt, or an unknown kind", "application/json",
         @error_schema},
      bad_gateway: {"The embedder upstream is down", "application/json", @error_schema}
    ]
  )
end
