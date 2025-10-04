defmodule Quicksilver.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Core infrastructure
      # {Registry, keys: :unique, name: Quicksilver.Registry},
      {Registry, keys: :unique, name: Quicksilver.AgentRegistry},

      # Agent manager (MVP!)
      Quicksilver.Agents.Manager
    ]

    opts = [strategy: :one_for_one, name: Quicksilver.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
