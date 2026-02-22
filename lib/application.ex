defmodule Quicksilver.Application do
  use Application

  @impl true
  def start(_type, _args) do
    require Logger

    :erlang.process_flag(:trap_exit, true)

    children = [
      # LLM Engine — always starts, zero agentic dependencies
      Quicksilver.LlmEngine.Backends.LlamaCpp,

      # Agentic — tools registry and cache (agents are stateless, no process needed)
      Quicksilver.Agentic.Tools.Registry,
      Quicksilver.Agentic.RepositoryMap.Cache.Server
    ]

    opts = [strategy: :one_for_one, name: Quicksilver.Supervisor]

    result = Supervisor.start_link(children, opts)

    # Always register tools on startup — they're backend-independent
    if match?({:ok, _}, result) do
      Quicksilver.Agentic.Tools.register_default_tools()
      Logger.info("#{length(Quicksilver.Agentic.Tools.list_tools())} tools registered")
    end

    result
  end

  @impl true
  def stop(_state) do
    :ok
  end
end
