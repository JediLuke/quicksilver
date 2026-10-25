defmodule Quicksilver.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Selected by the :backend config key (see config/config.exs)
    {backend_module, backend_server} = Quicksilver.Backends.configured()

    children = [
      {Registry, keys: :unique, name: Quicksilver.AgentRegistry},
      backend_module,
      Quicksilver.Tools.Registry,
      Quicksilver.RepositoryMap.Cache.Server,
      {Quicksilver.Agents.ToolAgent,
       backend_module: backend_module,
       backend_pid: backend_server,
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
