defmodule Quicksilver.Agents.Manager do
  @moduledoc """
  Simple agent manager for supervising agent processes
  """
  use DynamicSupervisor
  require Logger

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a new agent
  """
  def start_agent(agent_module, agent_config) do
    spec = {agent_module, agent_config}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Stop an agent
  """
  def stop_agent(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc """
  List all running agents
  """
  def list_agents do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
