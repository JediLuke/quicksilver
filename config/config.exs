import Config

# MVP Configuration
config :quicksilver,
  # LlamaCpp backend configuration
  llama_cpp: %{
    server_path: "/home/luke/workbench/tools/llama.cpp/build/bin/llama-server",
    model_path: "/home/luke/workbench/models/",
    model_file: "qwen2.5-coder-32b-instruct-q4_k_m.gguf",
    port: 8080,
    threads: 16,
    ctx_size: 8192,
    gpu_layers: 99
  }

# Import environment specific config
# import_config "#{config_env()}.exs"
