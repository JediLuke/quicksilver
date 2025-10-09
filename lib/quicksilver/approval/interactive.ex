defmodule Quicksilver.Approval.Interactive do
  @moduledoc """
  Interactive approval for dangerous operations with diff previews.
  """

  @doc """
  Request approval from the user for a specific action.
  Returns :approved, :rejected, or :quit_session.
  """
  @spec request_approval(atom(), map()) :: :approved | :rejected | :quit_session
  def request_approval(action_type, details) do
    IO.puts("\n" <> IO.ANSI.yellow() <> "═══ AI Agent Request ═══" <> IO.ANSI.reset())

    case action_type do
      :file_edit -> show_file_edit(details)
      :file_create -> show_file_create(details)
      :file_delete -> show_file_delete(details)
      :shell_command -> show_shell_command(details)
    end

    prompt_user()
  end

  defp show_file_edit(%{path: path, diff: diff}) do
    IO.puts("\n📝 Edit File: " <> IO.ANSI.bright() <> path <> IO.ANSI.reset())
    IO.puts("\nChanges:")
    show_diff(diff)
  end

  defp show_file_create(%{path: path, content: content}) do
    IO.puts("\n📄 Create File: " <> IO.ANSI.bright() <> path <> IO.ANSI.reset())
    lines = String.split(content, "\n") |> length()
    bytes = byte_size(content)
    IO.puts("Size: #{lines} lines, #{bytes} bytes")
    IO.puts("\nPreview (first 20 lines):")
    content
    |> String.split("\n")
    |> Enum.take(20)
    |> Enum.each(&IO.puts("  " <> &1))
  end

  defp show_file_delete(%{path: path}) do
    IO.puts("\n🗑️  Delete File: " <> IO.ANSI.bright() <> path <> IO.ANSI.reset())
  end

  defp show_shell_command(%{command: cmd, working_dir: dir}) do
    IO.puts("\n⚡ Shell Command")
    IO.puts("Directory: #{dir}")
    IO.puts("Command: " <> IO.ANSI.cyan() <> cmd <> IO.ANSI.reset())
  end

  defp show_diff(diff) do
    diff
    |> String.split("\n")
    |> Enum.each(fn line ->
      cond do
        String.starts_with?(line, "+") ->
          IO.puts(IO.ANSI.green() <> line <> IO.ANSI.reset())
        String.starts_with?(line, "-") ->
          IO.puts(IO.ANSI.red() <> line <> IO.ANSI.reset())
        String.starts_with?(line, "@") ->
          IO.puts(IO.ANSI.cyan() <> line <> IO.ANSI.reset())
        true ->
          IO.puts(line)
      end
    end)
  end

  defp prompt_user do
    IO.puts("\n" <> IO.ANSI.cyan() <> "[A]pprove  [R]eject  [V]iew full  [Q]uit session" <> IO.ANSI.reset())

    case IO.gets("Choice: ") |> String.trim() |> String.downcase() do
      "a" -> :approved
      "r" -> :rejected
      "v" -> {:view_full, prompt_user()}
      "q" -> :quit_session
      _ -> prompt_user()
    end
  end
end
