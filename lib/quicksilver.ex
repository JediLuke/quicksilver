defmodule Quicksilver do
  @moduledoc """
  Quicksilver - The Alchemical Agentic Framework for Elixir

  ## Quick Start

  1. Update config/config.exs with your llama.cpp paths
  2. Start your application: `iex -S mix`
  3. Start the terminal chat:

      Quicksilver.chat()

  ## Architecture

  Quicksilver is organized into two independent layers:

  - **LLM Engine** (`Quicksilver.LlmEngine`) — standalone local LLM server management
  - **Agentic** (`Quicksilver.Agentic`) — agents, tools, approval, repository map, and interfaces
  """

  @doc """
  Start the terminal chat interface.
  """
  def chat(opts \\ []) do
    Quicksilver.Agentic.Interfaces.Terminal.start(opts)
  end
end
