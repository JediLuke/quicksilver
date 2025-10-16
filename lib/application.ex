defmodule Quicksilver.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Quicksilver.AgentRegistry},
      Quicksilver.Backends.LlamaCpp,
      Quicksilver.Tools.Registry,
      Quicksilver.RepositoryMap.Cache.Server,
      {Quicksilver.Agents.ToolAgent,
       backend_module: Quicksilver.Backends.LlamaCpp,
       backend_pid: LlamaCpp,
       name: Quicksilver.Agents.ToolAgent},
      Quicksilver.Agents.Manager
    ]

    opts = [strategy: :one_for_one, name: Quicksilver.Supervisor]

    # Start supervisor
    result = Supervisor.start_link(children, opts)

    # Register default tools after successful startup
    if match?({:ok, _}, result) do
      Quicksilver.Tools.register_default_tools()
    end

    result
  end
end
