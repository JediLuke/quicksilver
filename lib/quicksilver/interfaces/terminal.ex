defmodule Quicksilver.Interfaces.Terminal do
  @moduledoc """
  Simple terminal chat interface for Quicksilver.

  Uses a `Quicksilver.Conversation` struct to manage the conversation thread.
  """

  alias Quicksilver.Conversation

  defmodule State do
    defstruct [:context]
  end

  def start(opts \\ []) do
    backend = Keyword.get(opts, :backend, :llama_cpp)

    case Quicksilver.LlmEngine.health_check(backend: backend) do
      :ok ->
        ctx = Conversation.new(
          tools: Keyword.get(opts, :tools),
          backend: backend,
          backend_state: Keyword.get(opts, :backend_state, %{}),
          workspace_root: Keyword.get(opts, :workspace_root, File.cwd!()),
          system_prompt: Keyword.get(opts, :system_prompt),
          history: Keyword.get(opts, :history, []),
          max_iterations: Keyword.get(opts, :max_iterations, 50),
          per_iteration_timeout: Keyword.get(opts, :per_iteration_timeout, 300_000),
          approve: Keyword.get(opts, :approve, &Quicksilver.Interfaces.Interactive.request_approval/2)
        )

        state = %State{context: ctx}
        print_welcome(ctx)
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

  defp print_welcome(ctx) do
    tools_info = case ctx.tools do
      :none -> "none"
      :all -> "#{length(Quicksilver.Tools.list_tools())} (all)"
      list when is_list(list) -> "#{length(list)} (#{Enum.join(list, ", ")})"
    end

    IO.puts("""

    Quicksilver - Terminal Chat
    ===========================

    Backend: #{ctx.backend}
    Tools: #{tools_info}

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
        loop(%{state | context: Conversation.clear(state.context)})

      {:command, :history} ->
        show_history(Conversation.history(state.context))
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
    tools = Quicksilver.Tools.list_tools()

    IO.puts("\nAvailable Tools (#{length(tools)}):")
    IO.puts(String.duplicate("-", 60))

    Enum.each(tools, fn tool ->
      IO.puts("\n  * #{tool.name}")
      IO.puts("    #{tool.description}")
    end)

    IO.puts("")
  end

  defp show_history([]) do
    IO.puts("\n--- No history ---\n")
  end

  defp show_history(history) do
    IO.puts("\n--- History ---")
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

    case Conversation.send(state.context, text) do
      {:ok, response, updated_ctx} ->
        response = String.trim(response)
        IO.puts(response)
        IO.puts("")
        %{state | context: updated_ctx}

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
