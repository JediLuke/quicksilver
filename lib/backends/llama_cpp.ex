defmodule Quicksilver.Backends.LlamaCpp do
  @moduledoc """
  LlamaCpp backend with proper initialization
  """
  use GenServer
  @behaviour Quicksilver.Backends.Backend
  require Logger

  defstruct [:config, :server_pid, :base_url, :ready]

  @impl Quicksilver.Backends.Backend
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end


  @impl GenServer
  def init(config) do
    state = %__MODULE__{
      config: config,
      base_url: "http://localhost:#{config.port}",
      ready: false
    }

    # Start initialization asynchronously to avoid circular calls
    send(self(), :initialize)

    {:ok, state}
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

  @impl GenServer
  def handle_info(:initialize, state) do
    case ensure_server_running(state) do
      :ok ->
        {:noreply, %{state | ready: true}}
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
    if server_running?(state.config.port) do
      Logger.info("✅ llama.cpp server already running")
      wait_for_health(state.base_url)
    else
      case check_model_file(state.config) do
        {:ok, model_path} ->
          start_server(%{state.config | model_path: model_path})
          wait_for_health(state.base_url)
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

  defp server_running?(port) do
    case :gen_tcp.connect(~c"localhost", port, [:binary, packet: :raw, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true
      {:error, _} ->
        false
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
      "--n-gpu-layers", to_string(config.gpu_layers || 99)
    ]

    # Add chat template if specified
    args = if config[:chat_template] do
      args ++ ["--chat-template", config.chat_template]
    else
      args
    end

    spawn(fn ->
      System.cmd(config.server_path, args, into: IO.stream(:stdio, :line))
    end)
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
