defmodule Quicksilver.LlmEngine.Backends.ClaudeCli do
  @moduledoc """
  Claude CLI backend using `claude -p` for headless operation.

  Stateless module — no GenServer needed. Uses `complete_with_state/3` to track
  the `session_id` across calls for conversation continuity via `--resume`.

  First call: `claude -p "prompt" --output-format json`
  Subsequent calls: `claude -p "prompt" --resume $session_id --output-format json`

  ## Options

  These can be passed via the `options` keyword list:

  - `:plan` — boolean, enables planning mode (`--plan`)
  - `:model` — string, model to use (e.g. `"claude-sonnet-4-6"`)
  - `:max_turns` — integer, limit the number of agentic turns (`--max-turns`)
  - `:allowed_tools` — list of strings, restrict which tools Claude can use (`--allowedTools`)
  - `:system_prompt` — string, system prompt to pass (`--system-prompt`)

  ## Requirements

  The `claude` CLI must be installed and available in PATH.
  """

  @behaviour Quicksilver.LlmEngine.Backend

  require Logger

  @impl true
  def complete(messages, options \\ []) do
    prompt = messages_to_prompt(messages)

    case run_claude(prompt, nil, options) do
      {:ok, response, _session_id} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Quicksilver.LlmEngine.Backend
  def complete_with_state(messages, state, options \\ []) do
    session_id = Map.get(state, :session_id)

    # When resuming a session, Claude already has the history — only send the latest message.
    # When starting fresh, send the full prompt.
    prompt =
      if session_id do
        extract_latest_message(messages)
      else
        messages_to_prompt(messages)
      end

    case run_claude(prompt, session_id, options) do
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

  @default_timeout 120_000

  defp run_claude(prompt, session_id, options) do
    args = build_args(prompt, session_id, options)
    timeout = Keyword.get(options, :timeout, @default_timeout)

    Logger.info("Calling Claude CLI#{if session_id, do: " (resuming session)", else: ""}...")

    claude_path = System.find_executable("claude")
    # Spawn via /bin/sh to redirect stdin from /dev/null — without this,
    # the Port keeps a stdin pipe open and Claude CLI may hang waiting for it.
    shell_cmd = "#{claude_path} #{Enum.map_join(args, " ", &shell_escape/1)} < /dev/null"

    port = Port.open({:spawn, shell_cmd}, [
      :binary, :exit_status, :stderr_to_stdout,
      env: [
        {~c"CLAUDECODE", false},
        {~c"CLAUDE_CODE_ENTRYPOINT", false}
      ]
    ])

    collect_port_output(port, "", timeout)
  rescue
    e ->
      {:error, "Failed to run claude CLI: #{Exception.message(e)}"}
  end

  defp collect_port_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        parse_output(acc)

      {^port, {:exit_status, code}} ->
        Logger.error("Claude CLI failed (exit #{code}): #{String.slice(acc, 0..500)}")
        {:error, "Claude CLI failed (exit #{code}): #{String.slice(acc, 0..200)}"}
    after
      timeout ->
        Port.close(port)
        Logger.error("Claude CLI timed out after #{div(timeout, 1000)}s")
        {:error, "Claude CLI timed out after #{div(timeout, 1000)}s"}
    end
  end

  defp build_args(prompt, session_id, options) do
    base = ["-p", prompt, "--output-format", "json"]

    base
    |> maybe_add_resume(session_id)
    |> maybe_add_plan(Keyword.get(options, :plan))
    |> maybe_add_model(Keyword.get(options, :model))
    |> maybe_add_max_turns(Keyword.get(options, :max_turns))
    |> maybe_add_allowed_tools(Keyword.get(options, :allowed_tools))
    |> maybe_add_system_prompt(Keyword.get(options, :system_prompt))
  end

  defp maybe_add_resume(args, nil), do: args
  defp maybe_add_resume(args, session_id), do: args ++ ["--resume", session_id]

  defp maybe_add_plan(args, true), do: args ++ ["--plan"]
  defp maybe_add_plan(args, _), do: args

  defp maybe_add_model(args, nil), do: args
  defp maybe_add_model(args, model), do: args ++ ["--model", model]

  defp maybe_add_max_turns(args, nil), do: args
  defp maybe_add_max_turns(args, n), do: args ++ ["--max-turns", to_string(n)]

  defp maybe_add_allowed_tools(args, nil), do: args
  defp maybe_add_allowed_tools(args, []), do: args
  defp maybe_add_allowed_tools(args, tools) do
    Enum.reduce(tools, args, fn tool, acc -> acc ++ ["--allowedTools", tool] end)
  end

  defp maybe_add_system_prompt(args, nil), do: args
  defp maybe_add_system_prompt(args, prompt), do: args ++ ["--system-prompt", prompt]

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

  # Extract just the latest user message content for resumed sessions.
  defp extract_latest_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      role = msg[:role] || msg["role"]
      content = msg[:content] || msg["content"]

      if role == "user", do: strip_prompt_formatting(content)
    end)
    |> Kernel.||("hello")
  end

  defp shell_escape(arg), do: "'#{String.replace(arg, "'", "'\\''")}'"

  defp messages_to_prompt(messages) do
    messages
    |> Enum.map(fn msg ->
      content = msg[:content] || msg["content"]
      strip_prompt_formatting(content)
    end)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  # The Conversation module wraps messages in completion-style formatting
  # ("User: ...\n\nAssistant:\n") meant for llama.cpp. Strip that for Claude CLI
  # since it handles conversation structure internally.
  defp strip_prompt_formatting(text) do
    text
    |> String.replace(~r/^User:\s*/m, "")
    |> String.replace(~r/^Assistant:\s*/m, "")
    |> String.replace(~r/^System:\s*/m, "")
    |> String.trim()
  end
end
