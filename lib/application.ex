defmodule Quicksilver.Application do
  use Application

  @impl true
  def start(_type, _args) do
    require Logger

    # Register cleanup handler for when VM shuts down
    # This ensures llama.cpp server is killed even on Ctrl+C
    :erlang.process_flag(:trap_exit, true)

    # Check if backend will auto-start
    backend_config = Application.get_env(:quicksilver, :llama_cpp)
    auto_start = Map.get(backend_config, :auto_start, false)

    # Base children that always start
    base_children = [
      {Registry, keys: :unique, name: Quicksilver.AgentRegistry},
      Quicksilver.Backends.LlamaCpp,
      Quicksilver.Tools.Registry,
      Quicksilver.RepositoryMap.Cache.Server
    ]

    # LLM-dependent agents (only start if backend is auto-starting)
    llm_dependent_agents = if auto_start do
      Logger.info("🤖 Starting LLM-dependent agents (backend auto_start: true)")
      [
        {Quicksilver.Agents.ToolAgent,
         backend_module: Quicksilver.Backends.LlamaCpp,
         backend_pid: LlamaCpp,
         name: Quicksilver.Agents.ToolAgent},
        Quicksilver.Agents.Manager
      ]
    else
      Logger.info("""
      ⏸️  Manual start mode (auto_start: false)

      Backend and agents are NOT starting automatically.

      To start manually:
        iex> Quicksilver.Backends.LlamaCpp.start_standalone()
        iex> Quicksilver.Backends.LlamaCpp.initialize()

      Or set auto_start: true in config/config.exs for automatic startup.
      """)
      []
    end

    children = base_children ++ llm_dependent_agents

    opts = [strategy: :one_for_one, name: Quicksilver.Supervisor]

    # Start supervisor
    result = Supervisor.start_link(children, opts)

    # Register tools only if agents are running
    # Tools are agent-specific resources, no point loading them without agents
    if match?({:ok, _}, result) and auto_start do
      Quicksilver.Tools.register_default_tools()
      Logger.info("✅ #{length(Quicksilver.Tools.list_tools())} tools registered for agents")
    end

    result
  end

  @impl true
  def stop(_state) do
    # This is called during graceful shutdown
    # Give the supervisor time to clean up children (including LlamaCpp backend)
    :ok
  end
end
