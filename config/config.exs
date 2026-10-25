import Config

# MVP Configuration
config :quicksilver,
  # Backend the ToolAgent uses: "llama_cpp" or "openai_compatible".
  # Override per run: QUICKSILVER_BACKEND=openai_compatible mix run start_chat.exs
  backend: System.get_env("QUICKSILVER_BACKEND", "llama_cpp"),

  # Any server speaking the OpenAI chat completions API with tool calling.
  # Examples (base_url / api_key_env):
  #   OpenRouter  https://openrouter.ai/api/v1   OPENROUTER_API_KEY
  #   OpenAI      https://api.openai.com/v1      OPENAI_API_KEY
  #   Mistral     https://api.mistral.ai/v1      MISTRAL_API_KEY
  #   Ollama      http://127.0.0.1:11434/v1      nil
  #   vLLM        http://127.0.0.1:8000/v1       nil
  openai_compatible: %{
    base_url: "https://openrouter.ai/api/v1",
    # Name of the env var holding the API key (nil for servers without auth).
    # Never put the key itself in this file - the repo is public.
    api_key_env: "OPENROUTER_API_KEY",
    model: "openai/gpt-oss-120b",
    # Per-response token budget (includes reasoning tokens)
    max_tokens: 4096
    # temperature: 0.2,
    # top_p: 0.95,
    # Echo the model's reasoning_content back in history. Off by default
    # because providers with strict schemas can reject the extra field.
    # send_reasoning: false
  },

  # LlamaCpp backend configuration
  llama_cpp: %{
    # Preferred: a launch script carrying the model-specific llama-server flags
    # (--jinja, --n-cpu-moe, ctx, sampling). Used by LlamaCpp.start_standalone/0.
    # Must serve on `port` below.
    launch_script: Path.expand("~/workbench/local_models/serve-gpt-oss-120b.sh"),
    # Fallback when no launch_script is set: Quicksilver builds generic args
    # from these (no MoE offload - not suitable for gpt-oss-120b on an 8GB GPU)
    server_path: Path.expand("~/workbench/local_models/llama.cpp/build/bin/llama-server"),
    model_path: Path.expand("~/workbench/local_models/models/gpt-oss-120b"),
    model_file: "gpt-oss-120b-MXFP4.gguf",
    port: 8080,
    # :chat       -> /v1/chat/completions with native tool calling. Required for
    #                models with their own chat/tool format (gpt-oss, Qwen3, ...).
    #                The server must apply the model's chat template (--jinja).
    # :completion -> legacy raw /completion with the JSON-in-text tool protocol
    api: :chat,
    # Model name sent with chat requests (as listed by GET /v1/models)
    model: "gpt-oss-120b",
    # Per-response token budget in :chat mode (includes reasoning tokens)
    max_tokens: 4096,
    threads: 16,
    ctx_size: 8192,
    gpu_layers: 99,
    # Set to false to prevent auto-starting the model on application boot
    # Useful when switching models or managing the server manually.
    # With false, Quicksilver connects to whatever server is listening on `port`
    # on the first request (server_path/model_* above are then unused).
    auto_start: false
  }

# Import environment specific config
# import_config "#{config_env()}.exs"
