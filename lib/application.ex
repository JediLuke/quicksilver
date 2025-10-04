defmodule Quicksilver.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Quicksilver.AgentRegistry},
      Quicksilver.Backends.LlamaCpp,
      Quicksilver.Agents.Manager
    ]

    opts = [strategy: :one_for_one, name: Quicksilver.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
