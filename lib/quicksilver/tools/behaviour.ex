defmodule Quicksilver.Tools.Behaviour do
  @moduledoc """
  Behaviour for tool implementations.

  All tools must implement this behaviour to be registered and used by the agent.
  Tools should be safe, well-documented, and handle errors gracefully.
  """

  @doc """
  Returns the unique name of the tool.

  This name is used by the LLM to invoke the tool.
  Should be descriptive and follow snake_case convention.
  """
  @callback name() :: String.t()

  @doc """
  Returns a human-readable description of what the tool does.

  This description is included in the system prompt to help the LLM
  understand when and how to use the tool.
  """
  @callback description() :: String.t()

  @doc """
  Returns a JSON schema describing the tool's parameters.

  The schema should follow JSON Schema format and include:
  - type: "object"
  - properties: map of parameter names to their schemas
  - required: list of required parameter names
  """
  @callback parameters_schema() :: map()

  @doc """
  Executes the tool with the given arguments and context.

  ## Parameters
    - args: Map of argument names to values (validated against schema)
    - context: Map containing execution context (workspace_root, etc.)

  ## Returns
    - {:ok, result} where result is a string representation of the tool output
    - {:error, reason} if execution fails
  """
  @callback execute(args :: map(), context :: map()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc """
  Request approval for a destructive operation.

  Calls the `approve` callback from the tool execution context. If no callback
  is set, defaults to `:rejected` — destructive operations require explicit
  opt-in from the caller (terminal injects an interactive callback, tests can
  pass an auto-approve function).

  ## Parameters
    - context: The tool execution context map
    - action_type: Atom describing the action (e.g. `:file_edit`, `:file_create`)
    - details: Map of action-specific details shown to the user

  ## Returns
    - `:approved`, `:rejected`, or `:quit_session`
  """
  @spec request_approval(map(), atom(), map()) :: :approved | :rejected | :quit_session
  def request_approval(context, action_type, details) do
    case Map.get(context, :approve) do
      nil -> :rejected
      approve_fn when is_function(approve_fn, 2) -> approve_fn.(action_type, details)
    end
  end
end
