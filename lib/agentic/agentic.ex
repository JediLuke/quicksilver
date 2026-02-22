defmodule Quicksilver.Agentic do
  @moduledoc """
  Public API facade for the Agentic layer.

  Provides a clean interface for conversations, tool management,
  and related functionality.
  """

  @doc """
  Create a new conversation.

  See `Quicksilver.Conversation.new/1` for options.
  """
  defdelegate new_conversation(opts \\ []), to: Quicksilver.Conversation, as: :new

  @doc """
  List all registered tools.
  """
  @spec list_tools() :: [map()]
  defdelegate list_tools(), to: Quicksilver.Agentic.Tools

  @doc """
  Register a custom tool module.
  """
  @spec register_tool(module()) :: {:ok, String.t()} | {:error, String.t()}
  defdelegate register_tool(tool_module), to: Quicksilver.Agentic.Tools

  @doc """
  Execute a tool by name.
  """
  @spec execute_tool(String.t(), map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  defdelegate execute_tool(name, args, context \\ %{}), to: Quicksilver.Agentic.Tools
end
