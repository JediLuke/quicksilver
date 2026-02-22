defmodule Quicksilver.Agentic do
  @moduledoc """
  Public API facade for the Agentic layer.

  Provides a clean interface for agent execution, tool management,
  and related functionality.
  """

  alias Quicksilver.Agentic.{Agent, Tools}

  @doc """
  Execute a task using the agentic loop with tool calling.

  See `Quicksilver.Agentic.Agent.execute_task/2` for options.
  """
  @spec execute_task(String.t(), keyword()) ::
          {:ok, String.t(), list()} | {:error, String.t()}
  defdelegate execute_task(task, opts \\ []), to: Agent

  @doc """
  List all registered tools.
  """
  @spec list_tools() :: [map()]
  defdelegate list_tools(), to: Tools

  @doc """
  Register a custom tool module.
  """
  @spec register_tool(module()) :: {:ok, String.t()} | {:error, String.t()}
  defdelegate register_tool(tool_module), to: Tools

  @doc """
  Execute a tool by name.
  """
  @spec execute_tool(String.t(), map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  defdelegate execute_tool(name, args, context \\ %{}), to: Tools
end
