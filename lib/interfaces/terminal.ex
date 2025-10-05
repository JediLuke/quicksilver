defmodule Quicksilver.Interfaces.Terminal do
  @moduledoc """
  Simple terminal chat interface for Quicksilver
  """

  def start do
    print_welcome()
    loop([])
  end

  defp print_welcome do
    IO.puts("""

    ⚗️  Quicksilver - Terminal Chat
    ═══════════════════════════════════

    Connected to LlamaCpp backend.
    Type 'help' for commands, 'exit' to quit, or just chat!

    """)
  end

  defp loop(history) do
    prompt = IO.gets("you> ") |> String.trim()

    case parse_command(prompt) do
      {:command, :help} ->
        show_help()
        loop(history)

      {:command, :exit} ->
        IO.puts("👋 Goodbye!")
        :ok

      {:command, :clear} ->
        IO.puts("\n--- History cleared ---\n")
        loop([])

      {:command, :history} ->
        show_history(history)
        loop(history)

      {:message, ""} ->
        loop(history)

      {:message, text} ->
        new_history = handle_message(text, history)
        loop(new_history)
    end
  end

  defp parse_command("help"), do: {:command, :help}
  defp parse_command("exit"), do: {:command, :exit}
  defp parse_command("quit"), do: {:command, :exit}
  defp parse_command("clear"), do: {:command, :clear}
  defp parse_command("history"), do: {:command, :history}
  defp parse_command(text), do: {:message, text}

  defp show_help do
    IO.puts("""

    Available commands:
    ─────────────────────
    help          - Show this help
    exit/quit     - Exit chat
    clear         - Clear conversation history
    history       - Show conversation history

    Just type normally to chat!

    """)
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

  defp handle_message(text, history) do
    # Build messages with history
    system_msg = %{
      role: "system",
      content: "You are a helpful AI assistant. Be concise and friendly."
    }

    user_msg = %{role: "user", content: text}
    messages = [system_msg] ++ history ++ [user_msg]

    IO.write("assistant> ")

    case Quicksilver.Backends.LlamaCpp.complete(LlamaCpp, messages) do
      {:ok, response} ->
        response = String.trim(response)
        IO.puts(response)
        IO.puts("")

        # Update history
        history ++ [user_msg, %{role: "assistant", content: response}]

      {:error, :not_ready} ->
        IO.puts("⏸️  Backend not ready yet, please wait...\n")
        history

      {:error, reason} ->
        IO.puts("❌ Error: #{inspect(reason)}\n")
        history
    end
  end
end
