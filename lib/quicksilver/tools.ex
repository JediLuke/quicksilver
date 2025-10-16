defmodule Quicksilver.Tools do
  @moduledoc """
  Convenience module for tool management and registration.

  Provides helper functions for registering default tools and
  managing the tools registry.
  """

  alias Quicksilver.Tools.{
    Registry,
    FileReader,
    SearchFiles,
    ListFiles,
    EditFile,
    CreateFile,
    RunTests,
    GetRepositoryContext
  }

  @doc """
  Register all default tools with the registry.

  This should be called after the application starts to make
  the built-in tools available.
  """
  @spec register_default_tools() :: :ok
  def register_default_tools do
    tools = [
      # Read-only tools
      FileReader,
      SearchFiles,
      ListFiles,
      GetRepositoryContext,

      # Write tools (require approval)
      EditFile,
      CreateFile,

      # Utility tools
      RunTests
    ]

    Enum.each(tools, fn tool ->
      case Registry.register(tool) do
        {:ok, _name} ->
          :ok

        {:error, reason} ->
          raise "Failed to register tool #{inspect(tool)}: #{reason}"
      end
    end)

    :ok
  end

  @doc """
  Register a custom tool module.
  """
  @spec register_tool(module()) :: {:ok, String.t()} | {:error, String.t()}
  def register_tool(tool_module) do
    Registry.register(tool_module)
  end

  @doc """
  List all registered tools.
  """
  @spec list_tools() :: [map()]
  def list_tools do
    Registry.list_tools()
  end

  @doc """
  Execute a tool by name.
  """
  @spec execute_tool(String.t(), map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute_tool(name, args, context \\ %{}) do
    Registry.execute_tool(name, args, context)
  end
end
