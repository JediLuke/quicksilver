defmodule Quicksilver.Backends.LlamaCpp do
  @moduledoc """
  LlamaCpp backend with proper initialization
  """
  use GenServer
  @behaviour Quicksilver.Backends.Backend
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

  def start_link do
    config = Application.get_env(:quicksilver, :llama_cpp)
    GenServer.start_link(__MODULE__, config, name: LlamaCpp)
  end

  @impl Quicksilver.Backends.Backend
  def complete(pid, messages, options \\ []) do
    GenServer.call(pid, {:complete, messages, options}, 30_000)
  end

  @impl Quicksilver.Backends.Backend
  def stream(_pid, _messages, _options) do
    {:error, :not_implemented}
  end

  @impl Quicksilver.Backends.Backend
  def health_check(pid) do
    GenServer.call(pid, :health_check)
  end

  @doc """
  Gracefully shutdown the backend and its managed server (if owned)
  """
  def shutdown do
    GenServer.stop(LlamaCpp, :normal)
  end

  @doc """
  Force shutdown the llama.cpp server even if not owned by us.
  Use with caution - this will kill any running llama.cpp server on the configured port.
  """
  def force_shutdown_server do
    GenServer.call(LlamaCpp, :force_shutdown_server)
  end

  @doc """
  Manually start a llama.cpp server and take ownership of it.
  Only works if no server is currently running.
  """
  def start_owned_server do
    GenServer.call(LlamaCpp, :start_owned_server, 120_000)
  end

  @doc """
  Start a standalone llama.cpp server (detached from Quicksilver).
  Perfect for development - start once, restart Quicksilver many times.

  ## Options
  - port: Override the configured port
  - Any other config key from :llama_cpp config

  ## Example
      # Start with default config
      Quicksilver.Backends.LlamaCpp.start_standalone()

      # Start on different port
      Quicksilver.Backends.LlamaCpp.start_standalone(port: 8081)
  """
  def start_standalone(opts \\ []) do
    config = Application.get_env(:quicksilver, :llama_cpp)
    config = Map.merge(config, Map.new(opts))

    model_path = config.model_path <> "/" <> config.model_file

    unless File.exists?(config.server_path) do
      {:error, "llama.cpp server not found at #{config.server_path}"}
    else
      unless File.exists?(model_path) do
        {:error, "Model not found at #{model_path}"}
      else
        args = [
          "--model", model_path,
          "--host", "127.0.0.1",
          "--port", to_string(config.port),
          "--threads", to_string(config.threads || 16),
          "--ctx-size", to_string(config.ctx_size || 8192),
          "--n-gpu-layers", to_string(config.gpu_layers || 99),
          "--log-disable"  # Suppress llama.cpp logs
        ]

        # Add chat template if specified
        args = if config[:chat_template] do
          args ++ ["--chat-template", config.chat_template]
        else
          args
        end

        Logger.info("""
        🚀 Starting standalone llama.cpp server on port #{config.port}

        This server runs independently - Quicksilver will connect without managing it.
        To stop: Quicksilver.Backends.LlamaCpp.stop_standalone()
        """)

        # Spawn detached - not linked to any process
        spawn(fn ->
          System.cmd(config.server_path, args)
        end)

        Logger.info("✅ Server starting... wait a moment for model to load")
        :ok
      end
    end
  end

  @doc """
  Stop a standalone server on the configured port (or specified port)
  """
  def stop_standalone(port \\ nil) do
    config = Application.get_env(:quicksilver, :llama_cpp)
    port = port || config.port

    case System.cmd("lsof", ["-ti", ":#{port}"], stderr_to_stdout: true) do
      {pids, 0} ->
        pids
        |> String.trim()
        |> String.split("\n")
        |> Enum.each(fn pid ->
          Logger.info("🛑 Stopping standalone server (PID: #{pid}) on port #{port}")
          System.cmd("kill", ["-15", pid])
        end)
        :ok
      _ ->
        Logger.info("No server found on port #{port}")
        {:error, :no_server_found}
    end
  end

  @doc """
  Check if server is running on configured port (or specified port)
  """
  def server_running?(port \\ nil) do
    config = Application.get_env(:quicksilver, :llama_cpp)
    port = port || config.port

    case :gen_tcp.connect(~c"localhost", port, [:binary, packet: :raw, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true
      {:error, _} ->
        false
    end
  end

  @impl GenServer
  def init(config) do
    state = %__MODULE__{
      config: config,
      server_port: nil,
      base_url: "http://localhost:#{config.port}",
      ready: false,
      owned_server: false
    }

    # Start initialization asynchronously to avoid circular calls
    send(self(), :initialize)

    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Clean up owned server on shutdown
    if state.owned_server && state.server_port do
      Logger.info("🛑 Shutting down llama.cpp server...")
      Port.close(state.server_port)
    end
    :ok
  end

  @impl GenServer
  def handle_info(:initialize, state) do
    case ensure_server_running(state) do
      {:ok, new_state} ->
        {:noreply, %{new_state | ready: true}}
      {:error, reason} ->
        Logger.error("Failed to initialize LlamaCpp: #{inspect(reason)}")
        {:stop, {:initialization_failed, reason}, state}
    end
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
  def handle_call(:force_shutdown_server, _from, state) do
    case kill_server_on_port(state.config.port) do
      :ok ->
        Logger.info("🛑 Forced shutdown of llama.cpp server on port #{state.config.port}")
        new_state = %{state | server_port: nil, owned_server: false, ready: false}
        {:reply, :ok, new_state}
      error ->
        {:reply, error, state}
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

  @impl GenServer
  def handle_call({:complete, messages, options}, _from, state) do
    if not state.ready do
      {:reply, {:error, :not_ready}, state}
    else
      # Convert messages to a prompt string
      prompt = messages_to_prompt(messages)

      payload = %{
        prompt: prompt,
        temperature: Keyword.get(options, :temperature, 0.7),
        top_p: Keyword.get(options, :top_p, 0.8),
        top_k: Keyword.get(options, :top_k, 40),
        repeat_penalty: Keyword.get(options, :repeat_penalty, 1.05),
        n_predict: Keyword.get(options, :n_predict, 512)
      }

      case Req.post("#{state.base_url}/completion", json: payload, receive_timeout: 60_000) do
        {:ok, %{status: 200, body: %{"content" => content}}} ->
          {:reply, {:ok, content}, state}
        {:ok, response} ->
          {:reply, {:error, {:unexpected_response, response}}, state}
        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  defp messages_to_prompt(messages) do
    Enum.map_join(messages, "\n", fn msg ->
      case msg.role do
        "system" -> "System: #{msg.content}"
        "user" -> "User: #{msg.content}"
        "assistant" -> "Assistant: #{msg.content}"
        _ -> msg.content
      end
    end) <> "\nAssistant:"
  end

  defp ensure_server_running(state) do
    if check_port_open(state.config.port) do
      Logger.info("✅ llama.cpp server already running (not owned by us)")
      case wait_for_health(state.base_url) do
        :ok -> {:ok, %{state | owned_server: false}}
        error -> error
      end
    else
      case check_model_file(state.config) do
        {:ok, model_path} ->
          server_port = start_server(%{state.config | model_path: model_path})
          case wait_for_health(state.base_url) do
            :ok -> {:ok, %{state | server_port: server_port, owned_server: true}}
            error ->
              Port.close(server_port)
              error
          end
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check_model_file(config) do
    # For MVP, just check if model_path exists
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
    # Find and kill process listening on port
    case System.cmd("lsof", ["-ti", ":#{port}"], stderr_to_stdout: true) do
      {pids, 0} ->
        pids
        |> String.trim()
        |> String.split("\n")
        |> Enum.each(fn pid ->
          Logger.info("Killing process #{pid} on port #{port}")
          System.cmd("kill", ["-15", pid])  # SIGTERM
        end)
        # Give it a moment to shutdown
        :timer.sleep(1000)
        :ok
      _ ->
        {:error, :no_process_found}
    end
  end

  defp start_server(config) do
    Logger.info("🔧 Starting llama.cpp server...")

    # Ensure llama.cpp binary exists
    unless File.exists?(config.server_path) do
      raise "llama.cpp server not found at #{config.server_path}. Please build or download it first."
    end

    args = [
      "--model", config.model_path <> "/" <> config.model_file,
      "--host", "127.0.0.1",
      "--port", to_string(config.port),
      "--threads", to_string(config.threads || 16),
      "--ctx-size", to_string(config.ctx_size || 8192),
      "--n-gpu-layers", to_string(config.gpu_layers || 99),
      "--log-disable"  # Suppress llama.cpp logs
    ]

    # Add chat template if specified
    args = if config[:chat_template] do
      args ++ ["--chat-template", config.chat_template]
    else
      args
    end

    # Use Port to create a linked external process
    port = Port.open(
      {:spawn_executable, config.server_path},
      [:binary, :exit_status, args: args]
    )

    Logger.info("🔗 llama.cpp server linked to Quicksilver (will shutdown with app)")
    port
  end

  defp wait_for_health(base_url, attempts \\ 0, max_attempts \\ 30) do
    if attempts >= max_attempts do
      {:error, :timeout}
    else
      :timer.sleep(2000)

      case Req.get("#{base_url}/health") do
        {:ok, %{status: 200}} ->
          Logger.info("🚀 Model ready!")
          :ok
        _ ->
          Logger.info("⏳ Waiting for model to load... (#{attempts + 1}/#{max_attempts})")
          wait_for_health(base_url, attempts + 1, max_attempts)
      end
    end
  end
end
