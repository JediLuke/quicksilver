defmodule Quicksilver do
  @moduledoc """
  Quicksilver - Ephemeral LLM Conversation Threads for Elixir

  ## Quick Start

      # Bare chat
      conv = Quicksilver.new_conversation()
      {:ok, response, conv} = Quicksilver.Conversation.send(conv, "Hello!")

      # Tool-calling conversation
      conv = Quicksilver.new_conversation(tools: :all, workspace_root: ".")
      {:ok, response, conv} = Quicksilver.Conversation.send(conv, "Read mix.exs")

      # Terminal chat interface
      Quicksilver.chat()

  ## Architecture

  Quicksilver is organized into three layers:

  - **Conversation** (`Quicksilver.Conversation`) — ephemeral conversation threads
  - **Agentic** (`Quicksilver.Agentic`) — tools, approval, repository map
  - **LLM Engine** (`Quicksilver.LlmEngine`) — standalone local LLM server management
  """

  @doc """
  Create a new conversation.

  See `Quicksilver.Conversation.new/1` for options.
  """
  defdelegate new_conversation(opts \\ []), to: Quicksilver.Conversation, as: :new

  @doc """
  Start the terminal chat interface.
  """
  def chat(opts \\ []) do
    Quicksilver.Agentic.Interfaces.Terminal.start(opts)
  end
end
