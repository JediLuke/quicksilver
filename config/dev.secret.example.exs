import Config

# Per-machine settings and API keys. Copy to config/dev.secret.exs (gitignored)
# and keep the block that matches how you run llama.cpp.

# A) Server started by a launch script that carries the model-specific flags
#    (--jinja, --n-cpu-moe, ...). Start it yourself, or from IEx with
#    Quicksilver.LlmEngine.Backends.LlamaCpp.start_standalone()
config :quicksilver, Quicksilver.LlmEngine.Backends.LlamaCpp,
  launch_script: Path.expand("~/workbench/local_models/serve-gpt-oss-120b.sh"),
  # Name sent with chat requests, as listed by GET /v1/models
  model: "gpt-oss-120b"

# B) Quicksilver starts and owns the server on boot
# config :quicksilver, Quicksilver.LlmEngine.Backends.LlamaCpp,
#   server_path: Path.expand("~/workbench/tools/llama.cpp/build/bin/llama-server"),
#   model_path: Path.expand("~/workbench/models"),
#   model_file: "Qwen3.5-27B-Q4_K_M.gguf",
#   # Vision projector for multimodal models (optional)
#   mmproj_file: "mmproj-F16.gguf",
#   auto_start: true

# API keys (alternatively export the env vars named in config/config.exs)
# config :quicksilver, Quicksilver.LlmEngine.Backends.Anthropic, api_key: "sk-ant-..."
# config :quicksilver, Quicksilver.LlmEngine.Backends.OpenAICompatible, api_key: "sk-or-..."
