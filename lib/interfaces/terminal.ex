defmodule Quicksilver.Interfaces.Terminal do
  @moduledoc """
  Simple terminal chat interface for Quicksilver with multi-agent support.

  Supports switching between different agents during a session.
  """

  @default_agent :tool_agent

  @available_agents %{
    tool_agent: %{
      name: "ToolAgent",
      description: "Agent with file reading and search capabilities",
      module: Quicksilver.Agents.ToolAgent,
      process_name: Quicksilver.Agents.ToolAgent
    }
    # Future agents can be added here:
    # coder: %{
    #   name: "Coder",
    #   description: "Agent specialized in writing code",
    #   module: Quicksilver.Agents.Coder,
    #   process_name: Quicksilver.Agents.Coder
    # }
  }

  defmodule State do
    defstruct current_agent: :tool_agent,
              history: []
  end

  def start(opts \\ []) do
    initial_agent = Keyword.get(opts, :agent, @default_agent)

    unless Map.has_key?(@available_agents, initial_agent) do
      IO.puts("❌ Unknown agent: #{initial_agent}")
      IO.puts("Available agents: #{Map.keys(@available_agents) |> Enum.join(", ")}")
      :error
    else
      state = %State{current_agent: initial_agent, history: []}
      print_welcome(state)
      loop(state)
    end
  end

  defp print_welcome(state) do
    agent_info = @available_agents[state.current_agent]
    tools = Quicksilver.Tools.list_tools()
    tool_count = length(tools)

    IO.puts("""

    ⚗️  Quicksilver - Terminal Chat
    ═══════════════════════════════════

    Current Agent: #{agent_info.name}
    #{agent_info.description}
    Tools Available: #{tool_count}

    Type 'help' for commands, 'exit' to quit, or just chat!

    """)
  end

  defp loop(state) do
    agent_info = @available_agents[state.current_agent]
    prompt = read_multi_line_input()

    case parse_command(prompt) do
      {:command, :help} ->
        show_help()
        loop(state)

      {:command, :exit} ->
        IO.puts("👋 Goodbye!")
        :ok

      {:command, :clear} ->
        IO.puts("\n--- History cleared ---\n")
        loop(%{state | history: []})

      {:command, :history} ->
        show_history(state.history)
        loop(state)

      {:command, :tools} ->
        show_tools()
        loop(state)

      {:command, :agents} ->
        show_agents(state.current_agent)
        loop(state)

      {:command, :agent} ->
        IO.puts("Current agent: #{agent_info.name}")
        IO.puts("Usage: agent <name> to switch agents\n")
        loop(state)

      {:switch_agent, agent_key} ->
        case switch_agent(state, agent_key) do
          {:ok, new_state} ->
            loop(new_state)

          {:error, reason} ->
            IO.puts("❌ #{reason}\n")
            loop(state)
        end

      {:message, ""} ->
        loop(state)

      {:message, text} ->
        new_state = handle_message(text, state)
        loop(new_state)
    end
  end

  defp parse_command("help"), do: {:command, :help}
  defp parse_command("exit"), do: {:command, :exit}
  defp parse_command("quit"), do: {:command, :exit}
  defp parse_command("clear"), do: {:command, :clear}
  defp parse_command("history"), do: {:command, :history}
  defp parse_command("tools"), do: {:command, :tools}
  defp parse_command("agents"), do: {:command, :agents}
  defp parse_command("agent"), do: {:command, :agent}

  defp parse_command("agent " <> agent_name) do
    agent_key = String.to_atom(agent_name)
    {:switch_agent, agent_key}
  end

  defp parse_command(text), do: {:message, text}

  defp show_help do
    IO.puts("""

    Available commands:
    ─────────────────────────────────
    help                - Show this help
    exit/quit           - Exit chat
    clear               - Clear conversation history
    history             - Show conversation history
    tools               - Show available tools
    agents              - List all available agents
    agent               - Show current agent
    agent <name>        - Switch to a different agent

    Multi-line input:
    ─────────────────────────────────
    End a line with \\ to continue on the next line.
    Example:
      you> Please fix these warnings \\
      ...> warning: undefined function
      ...> warning: unused variable

    The current agent will process your messages with full
    conversation history for better context awareness.

    """)
  end

  defp show_agents(current_agent) do
    IO.puts("\n🤖 Available Agents:")
    IO.puts(String.duplicate("─", 60))

    Enum.each(@available_agents, fn {key, info} ->
      marker = if key == current_agent, do: "→ ", else: "  "
      IO.puts("\n#{marker}#{key}")
      IO.puts("  #{info.name} - #{info.description}")
    end)

    IO.puts("\nUse 'agent <name>' to switch agents\n")
  end

  defp switch_agent(state, agent_key) do
    cond do
      agent_key == state.current_agent ->
        {:error, "Already using #{agent_key}"}

      Map.has_key?(@available_agents, agent_key) ->
        agent_info = @available_agents[agent_key]
        IO.puts("\n🔄 Switching to #{agent_info.name}...")
        IO.puts("#{agent_info.description}")
        IO.puts("(History preserved)\n")
        {:ok, %{state | current_agent: agent_key}}

      true ->
        available = Map.keys(@available_agents) |> Enum.join(", ")
        {:error, "Unknown agent: #{agent_key}. Available: #{available}"}
    end
  end

  defp show_tools do
    tools = Quicksilver.Tools.list_tools()

    IO.puts("\n🔧 Available Tools (#{length(tools)}):")
    IO.puts(String.duplicate("─", 60))

    Enum.each(tools, fn tool ->
      IO.puts("\n  • #{tool.name}")
      IO.puts("    #{tool.description}")
    end)

    IO.puts("")
  end

  defp show_history([]) do
    IO.puts("\n--- No conversation history ---\n")
  end

  defp show_history(history) do
    IO.puts("\n--- Conversation History ---")
    Enum.each(history, fn
      %{role: "user", content: content} ->
        IO.puts("you> #{content}")
      %{role: "assistant", content: content} ->
        IO.puts("assistant> #{content}")
      %{role: "system", content: _} ->
        :ok
    end)
    IO.puts("--- End History ---\n")
  end

  defp handle_message(text, state) do
    user_msg = %{role: "user", content: text}
    agent_info = @available_agents[state.current_agent]

    IO.write("#{agent_info.name}> ")

    # Route to the appropriate agent, passing conversation history
    case execute_with_agent(agent_info, text, state.history) do
      {:ok, response} ->
        response = String.trim(response)
        IO.puts(response)
        IO.puts("")

        # Update history
        new_history = state.history ++ [user_msg, %{role: "assistant", content: response}]
        %{state | history: new_history}

      {:error, :not_ready} ->
        IO.puts("""
        ⏸️  Backend not ready

        The LLM backend hasn't finished loading yet. This usually means:
        1. The model is still loading (large models take 30-60 seconds)
        2. The server failed to start (check logs above for errors)

        To check status:
          - Run: Quicksilver.Backends.LlamaCpp.health_check(LlamaCpp)
          - Or wait a moment and try again

        If the server failed to start, you should see error messages above.
        See TROUBLESHOOTING.md for help with common issues.
        """)
        state

      {:error, reason} ->
        IO.puts("❌ Error: #{inspect(reason)}\n")
        state
    end
  end

  defp execute_with_agent(agent_info, text, history) do
    # Check if agent module has execute_task/3 function (like ToolAgent)
    if function_exported?(agent_info.module, :execute_task, 3) do
      agent_info.module.execute_task(
        agent_info.process_name,
        text,
        workspace_root: File.cwd!(),
        conversation_history: history
      )
    else
      # Fallback for agents without execute_task - use direct LLM
      # This is for backward compatibility or simpler agents
      Quicksilver.Backends.LlamaCpp.complete(
        LlamaCpp,
        [%{role: "user", content: text}]
      )
    end
  end

  defp read_multi_line_input() do
    first_line = IO.gets("you> ")

    if first_line == :eof do
      ""
    else
      first_line = String.trim(first_line)

      # Check if user wants multi-line input (ends with backslash)
      if String.ends_with?(first_line, "\\") do
        # Remove the trailing backslash and read more lines
        base = String.trim_trailing(first_line, "\\")
        more_lines = read_continuation_lines([])
        Enum.join([base | more_lines], "\n") |> String.trim()
      else
        first_line
      end
    end
  end

  defp read_continuation_lines(acc) do
    line = IO.gets("...> ") |> String.trim()

    if String.ends_with?(line, "\\") do
      # Continue reading
      base = String.trim_trailing(line, "\\")
      read_continuation_lines([base | acc])
    else
      # Done - reverse to maintain order
      Enum.reverse([line | acc])
    end
  end
end
