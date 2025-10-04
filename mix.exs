defmodule Quicksilver.MixProject do
  use Mix.Project

  def project do
    [
      app: :quicksilver,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :wx, :observer],
      mod: {Quicksilver.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.4"},
      # {:jason, "~> 1.4"},
      # {:typed_struct, "~> 0.3"},
      # {:uuid, "~> 1.1"},
      # {:rambo, "~> 0.3"}  # For future Claude Code integration
    ]
  end
end
