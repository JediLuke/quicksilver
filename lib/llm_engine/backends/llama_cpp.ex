defmodule Quicksilver.LlmEngine.Backends.LlamaCpp do
  @moduledoc """
  LlamaCpp backend with proper initialization
  """
  use GenServer
  @behaviour Quicksilver.LlmEngine.Backend
  require Logger

  defstruct [:config, :server_port, :base_url, :ready, :owned_server]

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :permanent,
      type: :worker
    }
  end

  @default_config %{
    port: 8080,
    threads: 16,
    ctx_size: 8192,
    gpu_layers: 99,
    auto_start: false
  }

  @required_keys [:server_path, :model_path, :model_file]

  def start_link do
    config = Application.get_env(:quicksilver, __MODULE__) || []
    config = @default_config |> Map.merge(Map.new(config))

    # Validate required config when auto_start is enabled
    if config.auto_start do
      missing = Enum.filter(@required_keys, fn key -> !Map.has_key?(config, key) end)

      if missing != [] do
        raise """
        Missing required LlamaCpp config keys: #{inspect(missing)}

        Add this to your config/dev.exs:

            config :quicksilver, Quicksilver.LlmEngine.Backends.LlamaCpp,
              server_path: "/path/to/llama.cpp/build/bin/llama-server",
              model_path: "/path/to/models",
              model_file: "your-model.gguf",
              auto_start: true

        Or set auto_start: false to disable the LlamaCpp backend.
        """
      end
    end

    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl Quicksilver.LlmEngine.Backend
  def complete(messages, options \\ []) do
    # Use receive_timeout for LLM processing time (default 2min, streaming gets more)
    # GenServer.call timeout must be longer to account for HTTP + processing
    receive_timeout = Keyword.get(options, :timeout, 120_000)
    call_timeout = if Keyword.has_key?(options, :stream_callback),
      do: receive_timeout + 30_000,
      else: receive_timeout + 10_000
    GenServer.call(__MODULE__, {:complete, messages, options}, call_timeout)
  end

  @impl Quicksilver.LlmEngine.Backend
  def complete_with_state(messages, backend_state, options \\ []) do
    case complete(messages, options) do
      {:ok, response} -> {:ok, response, backend_state}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Quicksilver.LlmEngine.Backend
  def health_check(_options \\ []) do
    GenServer.call(__MODULE__, :health_check)
  end

  @doc """
  Gracefully shutdown the backend and its managed server (if owned)
  """
  def shutdown do
    GenServer.stop(__MODULE__, :normal)
  end

  @doc """
  Force shutdown the llama.cpp server even if not owned by us.
  Use with caution - this will kill any running llama.cpp server on the configured port.
  """
  def force_shutdown_server do
    GenServer.call(__MODULE__, :force_shutdown_server)
  end

  @doc """
  Manually start a llama.cpp server and take ownership of it.
  Only works if no server is currently running.
  """
  def start_owned_server do
    GenServer.call(__MODULE__, :start_owned_server, 120_000)
  end

  @doc """
  Manually initialize the backend (connect to existing server or start a new one).
  Useful when auto_start is disabled in config.
  """
  def initialize do
    GenServer.call(__MODULE__, :initialize, 120_000)
  end

  @doc """
  Restart the backend - force shutdown any running server and reinitialize.
  """
  def restart do
    Logger.info("Restarting LlamaCpp backend...")
    _ = force_shutdown_server()
    Process.sleep(1000)
    initialize()
  end

  @doc """
  Start a standalone llama.cpp server (detached from Quicksilver).
  Perfect for development - start once, restart Quicksilver many times.

  ## Options
  - port: Override the configured port
  - Any other config key from config

  ## Example
      # Start with default config
      Quicksilver.LlmEngine.Backends.LlamaCpp.start_standalone()

      # Start on different port
      Quicksilver.LlmEngine.Backends.LlamaCpp.start_standalone(port: 8081)
  """
  def start_standalone(opts \\ []) do
    config = Application.get_env(:quicksilver, __MODULE__) |> Map.new()
    config = Map.merge(config, Map.new(opts))

    model_path = config.model_path <> "/" <> config.model_file

    unless File.exists?(config.server_path) do
      error_msg = "llama.cpp server not found at #{config.server_path}"
      Logger.error(error_msg)
      {:error, error_msg}
    else
      unless File.exists?(model_path) do
        error_msg = "Model not found at #{model_path}"
        Logger.error(error_msg)
        {:error, error_msg}
      else
        # Check if port is already in use
        if check_port_open(config.port) do
          Logger.warning("Port #{config.port} is already in use. Connecting to existing server...")
          {:ok, :already_running}
        else

        cleanup_orphans(config.port)

        args = [
          "--model", model_path,
          "--host", "127.0.0.1",
          "--port", to_string(config.port),
          "--threads", to_string(config.threads || 16),
          "--ctx-size", to_string(config.ctx_size || 8192),
          "--n-gpu-layers", to_string(config.gpu_layers || 99)
        ]

        args = maybe_add_optional_arg(args, config, :mmproj_file, "--mmproj", config.model_path)
        args = maybe_add_optional_arg(args, config, :chat_template, "--chat-template")

        Logger.info("""
        Starting standalone llama.cpp server on port #{config.port}

        This server runs independently - Quicksilver will connect without managing it.
        To stop: Quicksilver.LlmEngine.Backends.LlamaCpp.stop_standalone()
        """)

        # Start server in detached mode
        spawn(fn ->
          cmd = """
          exec #{config.server_path} #{Enum.map_join(args, " ", &"\"#{&1}\"")} > /tmp/llama-server-#{config.port}.log 2>&1
          """

          System.cmd("sh", ["-c", cmd])
        end)

        # Give it a moment to start, then verify
        Logger.info("Waiting for server to start...")
        :timer.sleep(3000)

        # Check multiple times with backoff to handle slow model loading
        case wait_for_server_start(config.port, 10) do
          :ok ->
            # Write PID file for the standalone server
            case System.cmd("lsof", ["-ti", ":#{config.port}"], stderr_to_stdout: true) do
              {pid_str, 0} ->
                pid_str |> String.trim() |> String.split("\n") |> List.first() |> then(fn pid ->
                  case Integer.parse(pid) do
                    {os_pid, _} -> write_pid_file(config.port, os_pid)
                    _ -> :ok
                  end
                end)
              _ -> :ok
            end

            Logger.info("""
            Server started successfully!

            Server logs: /tmp/llama-server-#{config.port}.log
            Model will continue loading in the background (20-60 seconds for large models)
            You can monitor with: tail -f /tmp/llama-server-#{config.port}.log
            """)

            # Auto-initialize the backend to connect to the server
            case initialize() do
              :ok ->
                Logger.info("Backend connected to server automatically")
                :ok
              {:ok, :already_initialized} ->
                Logger.info("Backend already connected")
                :ok
              {:error, reason} ->
                Logger.warning("Could not auto-connect backend: #{inspect(reason)}")
                Logger.info("The server is running, but you'll need to wait for model loading to complete")
                Logger.info("Then run: Quicksilver.LlmEngine.Backends.LlamaCpp.initialize()")
                :ok
            end
          {:error, reason} ->
            # Read log file to diagnose
            log_content = case File.read("/tmp/llama-server-#{config.port}.log") do
              {:ok, content} -> content
              {:error, _} -> "Could not read log file"
            end

            error_diagnosis = diagnose_server_error(log_content, config)

            Logger.error("""
            Server failed to start on port #{config.port}

            #{error_diagnosis}

            Check the log file for details:
            tail -100 /tmp/llama-server-#{config.port}.log

            Or try running manually to see errors:
            #{config.server_path} -m #{model_path} --port #{config.port} -ngl #{config.gpu_layers || 99}
            """)
            {:error, reason}
        end
        end
      end
    end
  end

  @doc """
  Stop a standalone server on the configured port (or specified port)
  """
  def stop_standalone(port \\ nil) do
    config = Application.get_env(:quicksilver, __MODULE__) |> Map.new()
    port = port || config.port

    case System.cmd("lsof", ["-ti", ":#{port}"], stderr_to_stdout: true) do
      {pids, 0} ->
        pids
        |> String.trim()
        |> String.split("\n")
        |> Enum.each(fn pid ->
          Logger.info("Stopping standalone server (PID: #{pid}) on port #{port}")
          System.cmd("kill", ["-15", pid])
        end)
        remove_pid_file(port)
        :ok
      _ ->
        Logger.info("No server found on port #{port}")
        remove_pid_file(port)
        {:error, :no_server_found}
    end
  end

  @doc """
  Check if server is running on configured port (or specified port)
  """
  def server_running?(port \\ nil) do
    config = Application.get_env(:quicksilver, __MODULE__) |> Map.new()
    port = port || config.port

    case :gen_tcp.connect(~c"localhost", port, [:binary, packet: :raw, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true
      {:error, _} ->
        false
    end
  end

  @doc """
  Clean up orphaned llama-server processes on the configured port (or specified port).
  Escape hatch for when things go wrong — kills any orphan found via PID file or lsof.
  """
  def cleanup(port \\ nil) do
    config = Application.get_env(:quicksilver, __MODULE__) |> Map.new()
    port = port || config.port
    cleanup_orphans(port)
  end

  @impl GenServer
  def init(config) do
    # Trap exits so terminate/2 is called on shutdown
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      config: config,
      server_port: nil,
      base_url: "http://localhost:#{config.port}",
      ready: false,
      owned_server: false
    }

    auto_start = Map.get(config, :auto_start, false)

    if auto_start do
      send(self(), :initialize)
      Logger.info("Auto-starting backend (auto_start: true)")
    else
      Logger.debug("Backend auto-start disabled (auto_start: false or not set)")
    end

    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.owned_server && state.server_port do
      Logger.info("Shutting down owned llama.cpp server...")

      os_pid = case Port.info(state.server_port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

      try do
        Port.close(state.server_port)
        Logger.info("Port closed successfully")
      catch
        :error, :badarg ->
          Logger.debug("Port was already closed")
      end

      if os_pid do
        :timer.sleep(500)

        case System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true) do
          {_, 0} ->
            Logger.info("Sending SIGTERM to llama-server (PID: #{os_pid})")
            System.cmd("kill", ["-15", "#{os_pid}"])

            :timer.sleep(1000)

            case System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true) do
              {_, 0} ->
                Logger.warning("Process still running, sending SIGKILL")
                System.cmd("kill", ["-9", "#{os_pid}"])
              _ ->
                Logger.info("llama-server shut down successfully")
            end
          _ ->
            Logger.debug("Process already exited")
        end
      end

      remove_pid_file(state.config.port)
    end
    :ok
  end

  @impl GenServer
  def handle_info(:initialize, state) do
    case ensure_server_running(state) do
      {:ok, new_state} ->
        {:noreply, %{new_state | ready: true}}
      {:error, reason} ->
        Logger.warning("""
        Failed to auto-start backend: #{inspect(reason)}

        The backend GenServer is still running but not ready.
        You can try to start manually with:
          Quicksilver.LlmEngine.Backends.LlamaCpp.start_standalone()
          Quicksilver.LlmEngine.Backends.LlamaCpp.initialize()
        """)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({port, {:exit_status, status}}, %{server_port: port} = state) when is_port(port) do
    if status == 0 do
      Logger.info("llama.cpp server exited normally")
    else
      log_file = "/tmp/llama-server-owned-#{state.config.port}.log"
      log_tail = case File.read(log_file) do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.filter(fn line ->
            String.contains?(line, ["error", "Error", "failed", "Failed", "cudaMalloc", "out of memory", "exiting"])
          end)
          |> Enum.take(-10)
          |> Enum.join("\n")
        {:error, _} -> "Could not read log file"
      end

      error_diagnosis = diagnose_startup_failure()

      Logger.error("""
      llama-server failed to start (exit code #{status})

      Key errors from log:
      #{log_tail}

      #{error_diagnosis}

      Full log: #{log_file}
      """)
    end
    {:noreply, %{state | ready: false, server_port: nil, owned_server: false}}
  end

  @impl GenServer
  def handle_info({:EXIT, port, reason}, %{server_port: port} = state) when is_port(port) do
    Logger.warning("llama.cpp server port exited: #{inspect(reason)}")
    {:noreply, %{state | ready: false, server_port: nil}}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("""
    Received message in LlamaCpp backend: #{inspect(msg)}
    """)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:health_check, _from, state) do
    if state.ready do
      case Req.get("#{state.base_url}/health") do
        {:ok, %{status: 200}} -> {:reply, :ok, state}
        _ -> {:reply, {:error, :unhealthy}, state}
      end
    else
      {:reply, {:error, :not_ready}, state}
    end
  end

  @impl GenServer
  def handle_call({:complete, messages, options}, from, state) do
    if not state.ready do
      {:reply, {:error, :not_ready}, state}
    else
      callback = Keyword.get(options, :stream_callback)

      if callback do
        # Streaming — run in a Task to avoid blocking GenServer
        Task.start(fn ->
          result = do_streaming_complete(messages, options, callback, state)
          GenServer.reply(from, result)
        end)
        {:noreply, state}
      else
        result = do_non_streaming_complete(messages, options, state)
        {:reply, result, state}
      end
    end
  end

  @impl GenServer
  def handle_call(:force_shutdown_server, _from, state) do
    case kill_server_on_port(state.config.port) do
      :ok ->
        Logger.info("Forced shutdown of llama.cpp server on port #{state.config.port}")
        new_state = %{state | server_port: nil, owned_server: false, ready: false}
        {:reply, :ok, new_state}
      error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call(:initialize, _from, state) do
    if state.ready do
      {:reply, {:ok, :already_initialized}, state}
    else
      case ensure_server_running(state) do
        {:ok, new_state} ->
          {:reply, :ok, %{new_state | ready: true}}
        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl GenServer
  def handle_call(:start_owned_server, _from, state) do
    if state.ready do
      {:reply, {:error, :server_already_running}, state}
    else
      case check_model_file(state.config) do
        {:ok, model_path} ->
          server_port = start_server(%{state.config | model_path: model_path})
          case wait_for_health(state.base_url) do
            :ok ->
              new_state = %{state | server_port: server_port, owned_server: true, ready: true}
              {:reply, :ok, new_state}
            error ->
              if server_port, do: Port.close(server_port)
              {:reply, error, state}
          end
        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end


  defp do_non_streaming_complete(messages, options, state) do
    payload = build_payload(messages, options)

    case Req.post("#{state.base_url}/v1/chat/completions", json: payload, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
        {:ok, strip_thinking_tags(content)}
      {:ok, response} ->
        {:error, {:unexpected_response, response}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_streaming_complete(messages, options, callback, state) do
    url = "#{state.base_url}/v1/chat/completions"
    payload = build_payload(messages, options) |> Map.put("stream", true)
    acc = :erlang.make_ref()
    Process.put(acc, "")

    result = Req.post(url,
      json: payload,
      into: fn {:data, chunk}, {req, resp} ->
        parse_sse_chunks(chunk, callback, acc)
        {:cont, {req, resp}}
      end,
      receive_timeout: Keyword.get(options, :timeout, 120_000)
    )

    full_text = Process.get(acc, "")
    Process.delete(acc)

    case result do
      {:ok, %{status: 200}} ->
        callback.(%{type: :complete})
        {:ok, strip_thinking_tags(full_text)}
      {:ok, resp} ->
        callback.(%{type: :error, message: "Unexpected status: #{resp.status}"})
        {:error, {:unexpected_response, resp}}
      {:error, reason} ->
        callback.(%{type: :error, message: inspect(reason)})
        {:error, reason}
    end
  end

  defp build_payload(messages, options) do
    %{
      "messages" => Enum.map(messages, &encode_message/1),
      "temperature" => Keyword.get(options, :temperature, 0.7),
      "top_p" => Keyword.get(options, :top_p, 0.8),
      "max_tokens" => Keyword.get(options, :max_tokens, 4096)
    }
  end

  defp encode_message(%{role: role, content: content}) when is_binary(content),
    do: %{"role" => role, "content" => content}

  defp encode_message(%{role: role, content: content}) when is_list(content),
    do: %{"role" => role, "content" => Enum.map(content, &encode_content_block/1)}

  defp encode_content_block(%{type: "text", text: text}),
    do: %{"type" => "text", "text" => text}

  defp encode_content_block(%{type: "image_url", image_url: %{url: url}}),
    do: %{"type" => "image_url", "image_url" => %{"url" => url}}

  defp parse_sse_chunks(chunk, callback, acc) do
    chunk
    |> String.split("\n")
    |> Enum.each(fn line ->
      line = String.trim(line)
      case String.trim_leading(line, "data: ") do
        ^line when line == "" -> :ok
        ^line -> :ok  # not a data: line
        "[DONE]" -> :ok
        "" -> :ok
        json_str ->
          case Jason.decode(json_str) do
            {:ok, %{"choices" => [%{"delta" => %{"content" => token}} | _]}} when is_binary(token) ->
              callback.(%{type: :text, text: token})
              Process.put(acc, Process.get(acc, "") <> token)
            _ -> :ok
          end
      end
    end)
  end

  # TODO: Preserve thinking content instead of discarding — see memory/future_work.md
  defp strip_thinking_tags(text) do
    text
    |> String.replace(~r/<think>.*?<\/think>\s*/s, "")
    |> String.trim()
  end

  defp ensure_server_running(state) do
    if check_port_open(state.config.port) do
      Logger.info("llama.cpp server already running (not owned by us)")
      case wait_for_health(state.base_url) do
        :ok -> {:ok, %{state | owned_server: false}}
        error -> error
      end
    else
      case check_model_file(state.config) do
        {:ok, model_path} ->
          server_port = start_server(%{state.config | model_path: model_path})
          case wait_for_health(state.base_url) do
            :ok ->
              {:ok, %{state | server_port: server_port, owned_server: true}}
            error ->
              try do
                Port.close(server_port)
              catch
                :error, :badarg -> :ok
              end
              error
          end
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check_model_file(config) do
    if config[:model_path] && File.exists?(config.model_path) do
      {:ok, config.model_path}
    else
      {:error, :model_not_found}
    end
  end

  defp check_port_open(port) do
    case :gen_tcp.connect(~c"localhost", port, [:binary, packet: :raw, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true
      {:error, _} ->
        false
    end
  end

  defp kill_server_on_port(port) do
    case System.cmd("lsof", ["-ti", ":#{port}"], stderr_to_stdout: true) do
      {pids, 0} ->
        pids
        |> String.trim()
        |> String.split("\n")
        |> Enum.each(fn pid ->
          Logger.info("Killing process #{pid} on port #{port}")
          System.cmd("kill", ["-15", pid])
        end)
        :timer.sleep(1000)
        :ok
      _ ->
        {:error, :no_process_found}
    end
  end

  defp start_server(config) do
    Logger.info("Starting llama.cpp server (owned by Quicksilver)...")

    unless File.exists?(config.server_path) do
      raise "llama.cpp server not found at #{config.server_path}. Please build or download it first."
    end

    cleanup_orphans(config.port)

    model_path = config.model_path <> "/" <> config.model_file
    log_file = "/tmp/llama-server-owned-#{config.port}.log"

    args = [
      "--model", model_path,
      "--host", "127.0.0.1",
      "--port", to_string(config.port),
      "--threads", to_string(config.threads || 16),
      "--ctx-size", to_string(config.ctx_size || 8192),
      "--n-gpu-layers", to_string(config.gpu_layers || 99)
    ]

    args = maybe_add_optional_arg(args, config, :mmproj_file, "--mmproj", config.model_path)
    args = maybe_add_optional_arg(args, config, :chat_template, "--chat-template")

    shell_cmd = "exec #{config.server_path} #{Enum.map_join(args, " ", &shell_quote/1)} > #{log_file} 2>&1"

    Logger.info("Server output logged to: #{log_file}")

    port = Port.open(
      {:spawn, "/bin/sh -c #{shell_quote(shell_cmd)}"},
      [:exit_status]
    )

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> write_pid_file(config.port, os_pid)
      nil -> Logger.warning("Could not get OS PID for PID file")
    end

    Logger.info("llama.cpp server linked to Quicksilver (will shutdown with app)")
    Logger.info("Model loading in progress (this may take 30-60 seconds)...")
    port
  end

  defp maybe_add_optional_arg(args, config, key, flag, prefix \\ nil) do
    case config[key] do
      nil -> args
      value ->
        full_value = if prefix, do: prefix <> "/" <> value, else: value
        args ++ [flag, full_value]
    end
  end

  defp shell_quote(str) do
    "\"#{String.replace(str, "\"", "\\\"")}\""
  end

  defp wait_for_health(base_url, attempts \\ 0, max_attempts \\ 30) do
    if attempts >= max_attempts do
      {:error, :timeout}
    else
      :timer.sleep(2000)

      case Req.get("#{base_url}/health", retry: false) do
        {:ok, %{status: 200}} ->
          Logger.info("Model ready!")
          :ok
        {:ok, %{status: 503}} ->
          if rem(attempts, 5) == 0 do
            Logger.info("Model loading... (#{attempts + 1}/#{max_attempts})")
          end
          wait_for_health(base_url, attempts + 1, max_attempts)
        {:error, %Req.TransportError{reason: :econnrefused}} ->
          if attempts < 3 do
            wait_for_health(base_url, attempts + 1, max_attempts)
          else
            {:error, :server_died}
          end
        error ->
          Logger.debug("Health check error: #{inspect(error)}")
          wait_for_health(base_url, attempts + 1, max_attempts)
      end
    end
  end

  defp diagnose_server_error(output, config) do
    started_ok = String.contains?(output, "HTTP server is listening")
    loading_model = String.contains?(output, "loading model")

    cond do
      started_ok and loading_model ->
        """
        DIAGNOSIS: Server started but crashed during model loading

        The HTTP server started successfully on port #{config.port}, but the process
        exited while loading the model. Common causes:

        1. Process was killed/interrupted
           - Run: lsof -i :#{config.port}

        2. Model file corruption
           - Verify model file integrity

        3. Insufficient resources
           - VRAM: Run 'nvidia-smi' to check available memory

        4. llama.cpp compatibility
           - Your version: build #{extract_build_number(output)}

        To see the FULL error, run manually:
        #{config.server_path} -m #{config.model_path}/#{config.model_file} --port #{config.port} -ngl #{config.gpu_layers || 99}
        """

      String.contains?(output, "error: invalid argument") ->
        """
        DIAGNOSIS: Model format incompatibility

        The model file format is newer than your llama.cpp version supports.
        Update llama.cpp to the latest version.
        """

      String.contains?(output, "CUDA error") or String.contains?(output, "cudaMalloc failed") ->
        """
        DIAGNOSIS: GPU/CUDA error

        Check:
        1. Run 'nvidia-smi' to verify GPU is available
        2. Check VRAM usage - #{config.model_file} needs ~19GB VRAM
        3. Reduce gpu_layers in config if not enough VRAM

        Current config: gpu_layers = #{config.gpu_layers || 99}
        """

      String.contains?(output, "failed to load") or String.contains?(output, "cannot open") ->
        """
        DIAGNOSIS: Failed to load model file

        Model path: #{config.model_path}/#{config.model_file}

        Check:
        1. File exists and is readable
        2. File is not corrupted (re-download if needed)
        3. You have enough disk space
        """

      String.contains?(output, "Address already in use") or String.contains?(output, "bind: Address already in use") ->
        """
        DIAGNOSIS: Port #{config.port} is already in use

        Another process is using port #{config.port}.

        Find it: lsof -i :#{config.port}
        Kill it: killall llama-server
        """

      true ->
        """
        Unable to auto-diagnose this error.

        Try running manually to see full output:
        #{config.server_path} -m #{config.model_path}/#{config.model_file} --port #{config.port} -ngl #{config.gpu_layers || 99}
        """
    end
  end

  defp extract_build_number(output) do
    case Regex.run(~r/build: (\d+)/, output) do
      [_, number] -> number
      _ -> "unknown"
    end
  end

  defp wait_for_server_start(port, max_attempts, attempt \\ 1) do
    if attempt > max_attempts do
      {:error, :timeout}
    else
      if check_port_open(port) do
        :ok
      else
        :timer.sleep(1000)
        wait_for_server_start(port, max_attempts, attempt + 1)
      end
    end
  end

  defp diagnose_startup_failure do
    """
    The llama-server process started but then crashed immediately.
    Check the error messages above (they're from llama-server's stdout).

    Common issues:

    1. **Out of VRAM** (cudaMalloc failed: out of memory)
       -> Your GPU doesn't have enough free VRAM
       -> Check: nvidia-smi
       -> Fix: Close other GPU programs, or reduce ctx_size in config.exs

    2. **Model format incompatibility** (error: invalid argument)
       -> Your llama.cpp version is too old for this model
       -> Fix: Update llama.cpp

    3. **Model file corrupted**
       -> Re-download the model file
    """
  end

  # --- PID file management ---

  defp pid_file_path(port), do: "/tmp/quicksilver-llama-server-#{port}.pid"

  defp write_pid_file(port, os_pid) do
    File.write(pid_file_path(port), to_string(os_pid))
  end

  defp read_pid_file(port) do
    case File.read(pid_file_path(port)) do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {pid, ""} -> {:ok, pid}
          _ -> :error
        end
      {:error, _} -> :error
    end
  end

  defp remove_pid_file(port) do
    File.rm(pid_file_path(port))
  end

  defp process_alive?(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp cleanup_orphans(port) do
    # Stage 1: PID file check
    case read_pid_file(port) do
      {:ok, old_pid} ->
        if process_alive?(old_pid) do
          Logger.info("Found orphaned llama-server (PID: #{old_pid}), cleaning up...")
          System.cmd("kill", ["-15", to_string(old_pid)])
          :timer.sleep(1000)

          if process_alive?(old_pid) do
            Logger.warning("Orphan still alive, sending SIGKILL (PID: #{old_pid})")
            System.cmd("kill", ["-9", to_string(old_pid)])
            :timer.sleep(500)
          end
        end

        remove_pid_file(port)

      :error ->
        :ok
    end

    # Stage 2: lsof fallback — kill anything still holding the port
    case System.cmd("lsof", ["-ti", ":#{port}"], stderr_to_stdout: true) do
      {pids, 0} ->
        pids
        |> String.trim()
        |> String.split("\n")
        |> Enum.each(fn pid_str ->
          Logger.info("Killing leftover process #{pid_str} on port #{port}")
          System.cmd("kill", ["-15", pid_str])
        end)
        :timer.sleep(1000)

      _ ->
        :ok
    end

    :ok
  end
end
