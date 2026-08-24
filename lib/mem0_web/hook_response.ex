defmodule Mem0Web.HookResponse do
  @moduledoc """
  The JSON bodies Claude Code reads back from a hook.

  These are camelCase keys that form a contract with an external tool, and a
  typo in `hookSpecificOutput` fails *silently* — the hook simply has no effect,
  with no error anywhere. That is what earns them a module with a type and one
  constructor per event rather than a map literal in the controller.

  `decision` is absent from both shapes, for different reasons. On
  `UserPromptSubmit`, `"decision": "block"` erases the prompt and shows `reason`
  instead of running it. On `Stop`, it sends Claude back to work instead of
  ending the turn — which is what `stop_hook_active` in the payload exists to
  detect. Omitting the field is what lets the session proceed unchanged.
  """

  @typedoc "A hook response body, ready to encode."
  @type t :: %{hookSpecificOutput: map()}

  @doc """
  The `UserPromptSubmit` response.

  `additional_context` is appended to the prompt before the turn runs. It ships
  empty today — there is nothing to recall yet — and is the field recall lands
  on, which is why it is here now rather than added later.

  `session_title` renames the session in Claude Code, so a constant would
  relabel every session identically.
  """
  @spec user_prompt_submit(String.t(), String.t()) :: t()
  def user_prompt_submit(additional_context, session_title) do
    %{
      hookSpecificOutput: %{
        hookEventName: "UserPromptSubmit",
        additionalContext: additional_context,
        sessionTitle: session_title
      }
    }
  end

  @doc """
  The `Stop` response.

  Inert by construction: `stop.sh` detaches its `curl` and discards this body.
  It carries no `additionalContext` because `Stop` is the ingest path, not the
  recall one — the field is accepted by Claude Code there as non-error feedback
  to the model, and would be a second injection point if end-of-turn recall ever
  earned its place.
  """
  @spec stop() :: t()
  def stop, do: %{hookSpecificOutput: %{hookEventName: "Stop"}}
end
