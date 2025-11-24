import Config

# MVP Configuration
config :quicksilver,
  # LlamaCpp backend configuration
  llama_cpp: %{
    server_path: "/home/luke/workbench/tools/llama.cpp/build/bin/llama-server",
    model_path: "/home/luke/workbench/models/",
    model_file: "qwen2.5-coder-32b-instruct-q4_k_m.gguf",
    # model_file: "Llama-3.3-70B-Instruct-Q4_K_M.gguf",
    port: 8080,
    threads: 16,
    ctx_size: 8192,
    gpu_layers: 99,
    # Set to false to prevent auto-starting the model on application boot
    # Useful when switching models or managing the server manually
    auto_start: true
  }

# Import environment specific config
# import_config "#{config_env()}.exs"
