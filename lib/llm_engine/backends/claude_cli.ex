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
  - `:cwd` — string, working directory for the CLI process (enables project-scoped MCP servers)
  - `:permission_mode` — string, permission mode (e.g. `"acceptEdits"`)
  - `:stream_callback` — function, enables stream-json mode and receives normalized events

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
    stream_callback = Keyword.get(options, :stream_callback)

    try do
      args = build_args(prompt, session_id, options)
      timeout = Keyword.get(options, :timeout, @default_timeout)

      Logger.info("Calling Claude CLI#{if session_id, do: " (resuming session)", else: ""}#{if stream_callback, do: " [streaming]", else: ""}...")

      claude_path = System.find_executable("claude")
      # Spawn via /bin/sh to redirect stdin from /dev/null — without this,
      # the Port keeps a stdin pipe open and Claude CLI may hang waiting for it.
      # The port os_pid is the shell wrapper; killing it tears down the child too.
      shell_cmd = "#{claude_path} #{Enum.map_join(args, " ", &shell_escape/1)} < /dev/null"

      port_opts = [
        :binary, :exit_status, :stderr_to_stdout,
        env: [
          {~c"CLAUDECODE", false},
          {~c"CLAUDE_CODE_ENTRYPOINT", false}
        ]
      ]

      cwd = Keyword.get(options, :cwd)
      port_opts = if cwd, do: [{:cd, to_charlist(cwd)} | port_opts], else: port_opts

      port = Port.open({:spawn, shell_cmd}, port_opts)
      os_pid = port |> Port.info(:os_pid) |> elem(1)
      Quicksilver.SessionReaper.register(os_pid)

      Logger.info("ClaudeCli port opened (os_pid=#{os_pid}). stream_callback=#{inspect(is_function(stream_callback))} timeout=#{timeout}")

      if stream_callback do
        Logger.info("Entering stream mode")
        collect_stream_output(port, "", "", timeout, stream_callback, os_pid)
      else
        Logger.info("Entering non-stream mode")
        collect_port_output(port, "", timeout, os_pid)
      end
    catch
      kind, reason ->
        error_msg = "#{inspect(kind)}: #{inspect(reason)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        Logger.error("Claude CLI crashed: #{error_msg}")
        if stream_callback, do: safe_callback(stream_callback, %{type: :error, message: error_msg})
        {:error, "Failed to run claude CLI: #{inspect(reason)}"}
    end
  end

  defp collect_port_output(port, acc, timeout, os_pid) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, acc <> data, timeout, os_pid)

      {^port, {:exit_status, 0}} ->
        Quicksilver.SessionReaper.deregister(os_pid)
        parse_output(acc)

      {^port, {:exit_status, code}} ->
        Quicksilver.SessionReaper.deregister(os_pid)
        Logger.error("Claude CLI failed (exit #{code}): #{String.slice(acc, 0..500)}")
        {:error, "Claude CLI failed (exit #{code}): #{String.slice(acc, 0..200)}"}
    after
      timeout ->
        Quicksilver.SessionReaper.deregister(os_pid)
        Port.close(port)
        Logger.error("Claude CLI timed out after #{div(timeout, 1000)}s")
        {:error, "Claude CLI timed out after #{div(timeout, 1000)}s"}
    end
  end

  # Stream mode: buffer incoming chunks into lines, parse each NDJSON line, call callback.
  # Also listens for :stop_stream message so the caller can abort from another process.
  defp collect_stream_output(port, line_buf, acc, timeout, callback, os_pid) do
    receive do
      {^port, {:data, data}} ->
        # Append to line buffer and process complete lines
        new_buf = line_buf <> data
        {lines, remainder} = split_lines(new_buf)

        # Process each complete line
        for line <- lines, line != "" do
          process_stream_line(line, callback)
        end

        collect_stream_output(port, remainder, acc <> data, timeout, callback, os_pid)

      {^port, {:exit_status, 0}} ->
        Quicksilver.SessionReaper.deregister(os_pid)
        Logger.info("Stream port exited 0, acc=#{byte_size(acc)} bytes")
        # Process any remaining buffered line
        if line_buf != "" do
          process_stream_line(line_buf, callback)
        end

        parse_stream_output(acc, callback)

      {^port, {:exit_status, code}} ->
        Quicksilver.SessionReaper.deregister(os_pid)
        Logger.error("Stream port exited #{code}, acc=#{byte_size(acc)} bytes: #{String.slice(acc, 0..300)}")
        safe_callback(callback, %{type: :error, message: "CLI exited with code #{code}: #{String.slice(acc, 0..300)}"})
        {:error, "Claude CLI failed (exit #{code}): #{String.slice(acc, 0..200)}"}

      :stop_stream ->
        Quicksilver.SessionReaper.deregister(os_pid)
        Logger.info("Stream stopped by user — closing port")
        Port.close(port)
        safe_callback(callback, %{type: :error, message: "Stopped by user"})
        {:error, :stopped}
    after
      timeout ->
        Quicksilver.SessionReaper.deregister(os_pid)
        Port.close(port)
        Logger.error("Stream port timed out after #{div(timeout, 1000)}s")
        safe_callback(callback, %{type: :error, message: "Timed out after #{div(timeout, 1000)}s"})
        {:error, "Claude CLI timed out after #{div(timeout, 1000)}s"}
    end
  end

  # Split buffer into complete lines and a remainder (incomplete last line)
  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {Enum.slice(parts, 0..-2//1), List.last(parts)}
  end

  defp process_stream_line(line, callback) do
    line = String.trim(line)
    if line != "" do
      case Jason.decode(line) do
        {:ok, event} ->
          type = event["type"] || "no_type"
          Logger.info("Stream event: #{type}")
          dispatch_stream_event(event, callback)
        {:error, _} ->
          Logger.warning("Stream non-JSON line: #{String.slice(line, 0..120)}")
          # Still forward non-JSON as text so it shows up
          safe_callback(callback, %{type: :text, text: line <> "\n"})
      end
    end
  end

  # Forward all CLI stream-json events to the callback.
  # Extract readable content for each event type so the GUI can display everything.
  defp dispatch_stream_event(%{"type" => type} = event, callback) do
    safe_callback(callback, normalize_stream_event(type, event))
  end

  defp dispatch_stream_event(event, callback) do
    safe_callback(callback, %{type: :raw, text: inspect(event, limit: 5, printable_limit: 200) <> "\n"})
  end

  defp normalize_stream_event("assistant", %{"message" => %{"content" => content}}) when is_list(content) do
    text = Enum.map_join(content, "", fn
      %{"type" => "text", "text" => t} -> t
      %{"type" => "tool_use", "name" => name, "input" => input} when is_map(input) ->
        preview = input |> Enum.take(3) |> Enum.map_join(", ", fn {k, v} ->
          v_str = if is_binary(v), do: v, else: inspect(v, limit: 3, printable_limit: 80)
          "#{k}: #{String.slice(v_str, 0..60)}"
        end)
        "\n> Tool: #{name}(#{preview})\n"
      %{"type" => "tool_use", "name" => name} ->
        "\n> Tool: #{name}\n"
      other ->
        "\n> [#{other["type"] || "?"}]\n"
    end)
    %{type: :assistant, text: text}
  end

  defp normalize_stream_event("assistant", %{"message" => %{"content" => text}}) when is_binary(text) do
    %{type: :assistant, text: text}
  end

  defp normalize_stream_event("user", %{"message" => %{"content" => content}}) when is_list(content) do
    text = Enum.map_join(content, "", fn
      %{"type" => "tool_result", "content" => c} when is_binary(c) ->
        "> Result: #{String.slice(c, 0..150)}\n"
      %{"type" => "tool_result", "content" => blocks} when is_list(blocks) ->
        preview = Enum.map_join(blocks, "", fn
          %{"text" => t} -> String.slice(t, 0..150)
          _ -> ""
        end)
        "> Result: #{preview}\n"
      %{"type" => "tool_result"} ->
        "> Result: (ok)\n"
      _ -> ""
    end)
    %{type: :user, text: text}
  end

  defp normalize_stream_event("result", event) do
    %{type: :result, result: event["result"], session_id: event["session_id"]}
  end

  defp normalize_stream_event("system", event) do
    %{type: :system, text: "[system] #{String.slice(inspect(event["message"] || event), 0..150)}\n"}
  end

  defp normalize_stream_event(type, event) do
    %{type: :raw, text: "[#{type}] #{String.slice(inspect(event, limit: 3), 0..150)}\n"}
  end

  defp safe_callback(callback, event) do
    try do
      callback.(event)
    rescue
      e -> Logger.warning("Stream callback error: #{inspect(e)}")
    end
  end

  # Parse the full stream-json output to extract the final result.
  # CLI stream-json: last line is a "result" event, or we accumulate assistant text.
  defp parse_stream_output(raw_output, callback) do
    lines = raw_output |> String.split("\n") |> Enum.reverse()

    # Look for explicit "result" event (last line usually)
    result =
      Enum.find_value(lines, fn line ->
        line = String.trim(line)
        if line != "" do
          case Jason.decode(line) do
            {:ok, %{"type" => "result", "result" => result} = obj} ->
              {result, obj["session_id"]}
            _ -> nil
          end
        end
      end)

    case result do
      {text, session_id} ->
        safe_callback(callback, %{type: :complete, result: text, session_id: session_id})
        {:ok, text, session_id}

      nil ->
        # Fallback: accumulate text from assistant messages
        text =
          lines
          |> Enum.reverse()
          |> Enum.flat_map(fn line ->
            case Jason.decode(String.trim(line)) do
              {:ok, %{"type" => "assistant", "message" => %{"content" => content}}} when is_list(content) ->
                Enum.flat_map(content, fn
                  %{"type" => "text", "text" => t} -> [t]
                  _ -> []
                end)
              {:ok, %{"type" => "assistant", "message" => %{"content" => t}}} when is_binary(t) ->
                [t]
              _ -> []
            end
          end)
          |> Enum.join("\n")

        if text != "" do
          safe_callback(callback, %{type: :complete, result: text, session_id: nil})
          {:ok, text, nil}
        else
          # Last resort: treat as plain text
          {:ok, String.trim(raw_output), nil}
        end
    end
  end

  defp build_args(prompt, session_id, options) do
    streaming = Keyword.has_key?(options, :stream_callback)
    output_format = if streaming, do: "stream-json", else: "json"
    base = ["-p", prompt, "--output-format", output_format]
    base = if streaming, do: base ++ ["--verbose"], else: base

    base
    |> maybe_add_resume(session_id)
    |> maybe_add_plan(Keyword.get(options, :plan))
    |> maybe_add_model(Keyword.get(options, :model))
    |> maybe_add_max_turns(Keyword.get(options, :max_turns))
    |> maybe_add_allowed_tools(Keyword.get(options, :allowed_tools))
    |> maybe_add_system_prompt(Keyword.get(options, :system_prompt))
    |> maybe_add_permission_mode(Keyword.get(options, :permission_mode))
    |> maybe_add_dirs(Keyword.get(options, :add_dirs))
    |> maybe_add_disallowed_tools(Keyword.get(options, :disallowed_tools))
  end

  defp maybe_add_resume(args, nil), do: args
  defp maybe_add_resume(args, session_id), do: args ++ ["--resume", session_id]

  # plan mode is --permission-mode plan, not a standalone flag
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

  defp maybe_add_permission_mode(args, nil), do: args
  defp maybe_add_permission_mode(args, mode), do: args ++ ["--permission-mode", mode]

  defp maybe_add_dirs(args, nil), do: args
  defp maybe_add_dirs(args, []), do: args
  defp maybe_add_dirs(args, dirs) do
    Enum.reduce(dirs, args, fn dir, acc -> acc ++ ["--add-dir", dir] end)
  end

  defp maybe_add_disallowed_tools(args, nil), do: args
  defp maybe_add_disallowed_tools(args, []), do: args
  defp maybe_add_disallowed_tools(args, tools) do
    Enum.reduce(tools, args, fn tool, acc -> acc ++ ["--disallowedTools", tool] end)
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
