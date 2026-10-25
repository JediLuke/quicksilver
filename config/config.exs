import Config

# Backend used by Quicksilver.ask/2, new conversations and the terminal:
# llama_cpp | openai_compatible | openai | anthropic | claude_cli.
# Override per run: QUICKSILVER_BACKEND=claude_cli mix run start_chat.exs
config :quicksilver, backend: System.get_env("QUICKSILVER_BACKEND", "llama_cpp")

# llama.cpp server. Machine-specific settings (launch_script, server_path,
# model_path, model_file, auto_start) go in config/dev.secret.exs, which is
# gitignored - copy config/dev.secret.example.exs to get started.
config :quicksilver, Quicksilver.LlmEngine.Backends.LlamaCpp,
  port: 8080,
  # Native tool calling via /v1/chat/completions (gpt-oss, Qwen3, ...); the
  # server must apply the model's chat template (--jinja). false = the
  # JSON-in-text tool protocol, for models without tool-calling templates.
  native_tools: true,
  # Per-response token budget (includes reasoning tokens)
  max_tokens: 4096,
  # Sampling is left to the server (e.g. --temp in a launch script) unless set:
  # temperature: 0.7,
  # top_p: 0.8,
  threads: 16,
  ctx_size: 8192,
  gpu_layers: 99,
  # false = connect to a server you start yourself (on the first request);
  # true = start one on boot from server_path/model_path/model_file
  auto_start: false

# Any server speaking the OpenAI chat completions API with tool calling.
# Examples (base_url / api_key_env):
#   OpenRouter  https://openrouter.ai/api/v1   OPENROUTER_API_KEY
#   Mistral     https://api.mistral.ai/v1      MISTRAL_API_KEY
#   Ollama      http://127.0.0.1:11434/v1      nil
#   vLLM        http://127.0.0.1:8000/v1       nil
# api_key_env names the env var holding the key; or set api_key in
# config/dev.secret.exs. Never put a key in this file - the repo is public.
config :quicksilver, Quicksilver.LlmEngine.Backends.OpenAICompatible,
  base_url: "https://openrouter.ai/api/v1",
  api_key_env: "OPENROUTER_API_KEY",
  model: "openai/gpt-oss-120b",
  max_tokens: 4096

config :quicksilver, Quicksilver.LlmEngine.Backends.OpenAI,
  api_key: System.get_env("OPENAI_API_KEY"),
  model: "gpt-4o"

config :quicksilver, Quicksilver.LlmEngine.Backends.Anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-sonnet-4-6"

# Import environment specific config
import_config "#{config_env()}.exs"
