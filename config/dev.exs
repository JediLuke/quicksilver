import Config

# Import secrets (API keys, etc.) — not checked into git
if File.exists?(Path.expand("dev.secret.exs", __DIR__)) do
  import_config "dev.secret.exs"
end
