defmodule Quicksilver do
  @moduledoc """
  Quicksilver - The Alchemical Agentic Framework for Elixir

  ## Quick Start (MVP)

  1. Update config/config.exs with your llama.cpp paths
  2. Start your application: `iex -S mix`
  3. Run the example:

      # Start the backend
      {:ok, backend} = Quicksilver.start_backend()

      # Start an agent
      {:ok, agent} = Quicksilver.start_agent("my_agent", backend)

      # Send it a message
      Quicksilver.Agents.SampleAgent.send_message("my_agent", "What can you do?")

  The agent will continuously think and respond in a loop!
  """

  @doc """
  Start an agent
  """
  def start_agent(agent_module, opts \\ []) do
    Quicksilver.Agents.Manager.start_agent(agent_module, opts)
  end

  @doc """
  Start a sample agent
  """
  def start_sample_agent do
    start_agent(Quicksilver.Agents.SampleAgent,
      name: "Sample Agent"
    )
  end

  @doc """
  List all running agents
  """
  def list_agents do
    Quicksilver.Agents.Manager.list_agents()
  end

  def version, do: "0.1.0"
end
