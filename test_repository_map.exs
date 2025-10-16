#!/usr/bin/env elixir

# Test script for repository map generation

IO.puts("Starting Quicksilver application...")
Application.ensure_all_started(:quicksilver)

IO.puts("\nGenerating repository map for current directory...")
repo_path = File.cwd!()

case Quicksilver.RepositoryMap.AgentIntegration.get_or_generate(repo_path) do
  {:ok, map_data} ->
    IO.puts("\n✓ Repository map generated successfully!")
    IO.puts("\nStatistics:")
    IO.inspect(map_data.map.stats, pretty: true)

    IO.puts("\n\nGenerating context for task: 'improve tool agent'")
    {:ok, agent_pid} = Quicksilver.RepositoryMap.AgentIntegration.start_link(repo_path)

    case Quicksilver.RepositoryMap.AgentIntegration.get_context(
           agent_pid,
           "improve tool agent error handling",
           token_limit: 2000
         ) do
      {:ok, context} ->
        IO.puts("\n✓ Context generated:")
        IO.puts(context)

      {:error, reason} ->
        IO.puts("\n✗ Failed to generate context: #{inspect(reason)}")
    end

    GenServer.stop(agent_pid)

  {:error, reason} ->
    IO.puts("\n✗ Failed to generate repository map: #{inspect(reason)}")
end
