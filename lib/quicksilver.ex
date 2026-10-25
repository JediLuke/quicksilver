defmodule Quicksilver do
  @moduledoc """
  Quicksilver - Ephemeral LLM Conversation Threads for Elixir

  ## Quick Start

      # One-shot question (no conversation state)
      {:ok, answer} = Quicksilver.ask("What is 2 + 2?")

      # Bare chat
      conv = Quicksilver.new_conversation()
      {:ok, response, conv} = Quicksilver.Conversation.send(conv, "Hello!")

      # Tool-calling conversation
      conv = Quicksilver.new_conversation(tools: :all, workspace_root: ".")
      {:ok, response, conv} = Quicksilver.Conversation.send(conv, "Read mix.exs")

      # Terminal chat interface
      Quicksilver.chat()

  """

  @doc """
  Check if Quicksilver is available and ready.

  Returns true if the module is loaded. Useful for optional LLM integration
  where calling code may run with or without Quicksilver.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(__MODULE__) and Code.ensure_loaded?(Quicksilver.Conversation)
  end

  @doc """
  One-shot LLM call without maintaining conversation state.

  Good for simple queries where you don't need history.
  Returns `{:ok, response}` or `{:error, reason}`.

  ## Options
  Same as `new_conversation/1` - :backend, :system_prompt, etc.

  ## Examples

      {:ok, answer} = Quicksilver.ask("What is the capital of France?")
      {:ok, answer} = Quicksilver.ask("Explain GenServer", backend: :claude_cli)
  """
  @spec ask(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ask(message, opts \\ []) do
    conv = Quicksilver.Conversation.new(opts)
    case Quicksilver.Conversation.send(conv, message) do
      {:ok, response, _conv} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Create a new conversation.

  See `Quicksilver.Conversation.new/1` for options.
  """
  defdelegate new_conversation(opts \\ []), to: Quicksilver.Conversation, as: :new

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
