defmodule Quicksilver.Agentic.Interfaces.Terminal do
  @moduledoc """
  Simple terminal chat interface for Quicksilver.

  Uses a `Quicksilver.Conversation` struct to manage the conversation thread.
  """

  alias Quicksilver.Conversation
  alias Quicksilver.LlmEngine.Backends.LlamaCpp

  defmodule State do
    defstruct [:conversation]
  end

  def start(opts \\ []) do
    case LlamaCpp.health_check(LlamaCpp) do
      :ok ->
        conv = Conversation.new(
          tools: :all,
          workspace_root: File.cwd!(),
          history: Keyword.get(opts, :history, [])
        )

        state = %State{conversation: conv}
        print_welcome()
        loop(state)

      {:error, :not_ready} ->
        IO.puts("""
        Backend not ready.

        The LLM backend hasn't finished loading yet. This usually means:
        1. The model is still loading (large models take 30-60 seconds)
        2. The server failed to start

        To start manually:
          Quicksilver.LlmEngine.Backends.LlamaCpp.start_standalone()
          Quicksilver.LlmEngine.Backends.LlamaCpp.initialize()

        Or set auto_start: true in config/config.exs for automatic startup.
        """)
        :error

      {:error, reason} ->
        IO.puts("Backend error: #{inspect(reason)}")
        :error
    end
  end

  defp print_welcome do
    tools = Quicksilver.Agentic.Tools.list_tools()
    tool_count = length(tools)

    IO.puts("""

    Quicksilver - Terminal Chat
    ===========================

    Tools Available: #{tool_count}

    Type 'help' for commands, 'exit' to quit, or just chat!

    """)
  end

  defp loop(state) do
    prompt = read_multi_line_input()

    case parse_command(prompt) do
      {:command, :help} ->
        show_help()
        loop(state)

      {:command, :exit} ->
        IO.puts("Goodbye! Shutting down gracefully...")
        Task.start(fn ->
          :timer.sleep(500)
          System.stop(0)
        end)
        :timer.sleep(1000)
        :ok

      {:command, :clear} ->
        IO.puts("\n--- History cleared ---\n")
        loop(%{state | conversation: Conversation.clear(state.conversation)})

      {:command, :history} ->
        show_history(Conversation.history(state.conversation))
        loop(state)

      {:command, :tools} ->
        show_tools()
        loop(state)

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
  defp parse_command(text), do: {:message, text}

  defp show_help do
    IO.puts("""

    Available commands:
    -------------------
    help                - Show this help
    exit/quit           - Exit chat
    clear               - Clear conversation history
    history             - Show conversation history
    tools               - Show available tools

    Multi-line input:
    -------------------
    End a line with \\ to continue on the next line.
    Example:
      you> Please fix these warnings \\
      ...> warning: undefined function
      ...> warning: unused variable

    """)
  end

  defp show_tools do
    tools = Quicksilver.Agentic.Tools.list_tools()

    IO.puts("\nAvailable Tools (#{length(tools)}):")
    IO.puts(String.duplicate("-", 60))

    Enum.each(tools, fn tool ->
      IO.puts("\n  * #{tool.name}")
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
    IO.write("Agent> ")

    case Conversation.send(state.conversation, text) do
      {:ok, response, updated_conv} ->
        response = String.trim(response)
        IO.puts(response)
        IO.puts("")
        %{state | conversation: updated_conv}

      {:error, :not_ready} ->
        IO.puts("""
        Backend not ready.

        The LLM backend hasn't finished loading yet.
        Wait a moment and try again, or check:
          Quicksilver.LlmEngine.health_check()
        """)
        state

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}\n")
        state
    end
  end

  defp read_multi_line_input() do
    first_line = IO.gets("you> ")

    if first_line == :eof do
      ""
    else
      first_line = String.trim(first_line)

      if String.ends_with?(first_line, "\\") do
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
      base = String.trim_trailing(line, "\\")
      read_continuation_lines([base | acc])
    else
      Enum.reverse([line | acc])
    end
  end
end
