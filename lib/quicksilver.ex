defmodule Quicksilver do
  @moduledoc """
  Quicksilver - Ephemeral LLM Conversation Threads for Elixir

  ## Quick Start

      # Bare chat
      ctx = Quicksilver.new_context()
      {:ok, response, ctx} = Quicksilver.Context.send(ctx, "Hello!")

      # Tool-calling context
      ctx = Quicksilver.new_context(tools: :all, workspace_root: ".")
      {:ok, response, ctx} = Quicksilver.Context.send(ctx, "Read mix.exs")

      # Terminal chat interface
      Quicksilver.chat()

  """

  @doc """
  Create a new context.

  See `Quicksilver.Context.new/1` for options.
  """
  defdelegate new_context(opts \\ []), to: Quicksilver.Context, as: :new

  @doc """
  Start the terminal chat interface.
  """
  def chat(opts \\ []) do
    Quicksilver.Interfaces.Terminal.start(opts)
  end

  @doc """
  List all registered tools.
  """
  @spec list_tools() :: [map()]
  defdelegate list_tools(), to: Quicksilver.Tools

  @doc """
  Register a custom tool module.
  """
  @spec register_tool(module()) :: {:ok, String.t()} | {:error, String.t()}
  defdelegate register_tool(tool_module), to: Quicksilver.Tools

  @doc """
  Execute a tool by name.
  """
  @spec execute_tool(String.t(), map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  defdelegate execute_tool(name, args, context \\ %{}), to: Quicksilver.Tools
end
