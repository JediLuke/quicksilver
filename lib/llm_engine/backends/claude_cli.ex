defmodule Quicksilver.LlmEngine.Backends.ClaudeCli do
  @moduledoc """
  Claude CLI backend using `claude -p` for headless operation.

  Stateless module — no GenServer needed. Uses `complete_with_state/3` to track
  the `session_id` across calls for conversation continuity via `--resume`.

  First call: `claude -p "prompt" --output-format json`
  Subsequent calls: `claude -p "prompt" --resume $session_id --output-format json`

  ## Requirements

  The `claude` CLI must be installed and available in PATH.
  """

  @behaviour Quicksilver.LlmEngine.Backend

  require Logger

  @impl true
  def complete(messages, _options \\ []) do
    prompt = messages_to_prompt(messages)

    case run_claude(prompt, nil) do
      {:ok, response, _session_id} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Quicksilver.LlmEngine.Backend
  def complete_with_state(messages, state, _options \\ []) do
    prompt = messages_to_prompt(messages)
    session_id = Map.get(state, :session_id)

    case run_claude(prompt, session_id) do
      {:ok, response, new_session_id} ->
        new_state = if new_session_id, do: Map.put(state, :session_id, new_session_id), else: state
        {:ok, response, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def health_check(_options \\ []) do
    case System.find_executable("claude") do
      nil -> {:error, :claude_cli_not_found}
      _path -> :ok
    end
  end

  defp run_claude(prompt, session_id) do
    args = build_args(prompt, session_id)

    Logger.debug("Running claude CLI with args: #{inspect(args)}")

    case System.cmd("claude", args, stderr_to_stdout: true) do
      {output, 0} ->
        parse_output(output)

      {output, exit_code} ->
        Logger.error("Claude CLI failed (exit #{exit_code}): #{String.slice(output, 0..500)}")
        {:error, "Claude CLI failed (exit #{exit_code}): #{String.slice(output, 0..200)}"}
    end
  rescue
    e ->
      {:error, "Failed to run claude CLI: #{Exception.message(e)}"}
  end

  defp build_args(prompt, nil) do
    ["-p", prompt, "--output-format", "json"]
  end

  defp build_args(prompt, session_id) do
    ["-p", prompt, "--resume", session_id, "--output-format", "json"]
  end

  defp parse_output(output) do
    case Jason.decode(output) do
      {:ok, %{"result" => result, "session_id" => session_id}} ->
        {:ok, result, session_id}

      {:ok, %{"result" => result}} ->
        {:ok, result, nil}

      {:ok, parsed} ->
        # Try to extract text from various response formats
        text = extract_text(parsed)
        session_id = parsed["session_id"]
        {:ok, text, session_id}

      {:error, _} ->
        # If not JSON, treat the raw output as the response
        {:ok, String.trim(output), nil}
    end
  end

  defp extract_text(%{"content" => content}) when is_binary(content), do: content
  defp extract_text(%{"text" => text}) when is_binary(text), do: text
  defp extract_text(%{"message" => msg}) when is_binary(msg), do: msg
  defp extract_text(other), do: inspect(other)

  defp messages_to_prompt(messages) do
    messages
    |> Enum.map(fn msg ->
      role = msg[:role] || msg["role"]
      content = msg[:content] || msg["content"]

      case role do
        "system" -> content
        "user" -> content
        "assistant" -> "Previous response: #{content}"
        "tool" -> "Tool result: #{content}"
        _ -> content
      end
    end)
    |> Enum.join("\n\n")
  end
end
