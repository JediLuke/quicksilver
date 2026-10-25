# Running Quicksilver Locally (gpt-oss-120b)

Quicksilver talks to a llama.cpp server on `http://127.0.0.1:8080`. The server
is managed outside Quicksilver: it only runs while you have it started, and
Quicksilver connects to it on the first request.

## Quick start

Two terminals.

**1. Start the model server**

```
~/workbench/local_models/serve-gpt-oss-120b.sh
```

Wait until it says it's listening. Loading takes about 15s while the model file
is still in the page cache, and 30-60s after a reboot. Ctrl-C stops it.

**2. Start Quicksilver**

```
cd ~/workbench/quicksilver
mix run start_chat.exs
```

Startup order doesn't matter. If you get `{:error, :not_ready}`, the server
isn't up or is still loading; wait and send the message again.

## Using the chat

Type a task at the `you>` prompt, e.g. "read mix.exs and tell me what deps we use".

- Read-only tools (`read_file`, `search_files`, `list_files`) run straight away.
- `create_file` and `edit_file` show a diff first and ask you to
  **[A]**pprove, **[R]**eject or **[Q]**uit.
- Commands: `help`, `tools`, `agents`, `agent <name>`, `history`, `clear`, `exit`.
- End a line with `\` to continue typing on the next line.

## What to expect

Generation runs at about 23 tokens/s (MoE experts live in system RAM, attention
and KV cache on the 8GB GPU). Each agent step takes roughly 5-15s, so a
multi-step task can take a minute or two. The per-step timeout is 5 minutes.

## Tuning

Server settings are environment variables at the top of the launch script:

```
REASONING=high ~/workbench/local_models/serve-gpt-oss-120b.sh   # low | medium | high
CTX=131072 ~/workbench/local_models/serve-gpt-oss-120b.sh       # context size (default 65536)
```

Higher reasoning effort uses more of the per-response token budget. If you see
`{:empty_response, "length"}` errors, raise `max_tokens` in `config/config.exs`.

Sampling (`--temp 1.0 --top-p 1.0`) comes from the launch script. Quicksilver
only overrides it if you set `temperature` / `top_p` in `config/config.exs`.

## Starting the server from Quicksilver instead

```
iex -S mix
iex> Quicksilver.Backends.LlamaCpp.start_standalone()
```

This runs the `launch_script` from `config/config.exs` detached, logs to
`/tmp/llama-server-8080.log`, and waits up to ~3 minutes for the model to load.
Stop it with `Quicksilver.Backends.LlamaCpp.stop_standalone()` or
`pkill llama-server`.

## Switching models

Everything is in the `llama_cpp` map in `config/config.exs`:

| Key | Purpose |
|-----|---------|
| `api` | `:chat` = `/v1/chat/completions` with native tool calls (gpt-oss, Qwen3, ...; server needs `--jinja`). `:completion` = legacy raw `/completion` with the JSON-in-text tool protocol. |
| `model` | Name sent with chat requests, as listed by `curl http://127.0.0.1:8080/v1/models` |
| `port` | Port the server listens on |
| `launch_script` | Script used by `start_standalone/0` |
| `max_tokens` | Per-response token budget in `:chat` mode (includes reasoning tokens) |
| `auto_start` | Keep `false` when the server is managed externally |

Other launch scripts in `~/workbench/local_models/`: Qwen3-Coder-Next (port
8081) and Gemma (port 8082). Run one model at a time - they compete for VRAM.

## Using a hosted API (OpenRouter, OpenAI, Mistral, ...)

Any server that speaks the OpenAI chat completions API with tool calling works
through the `openai_compatible` backend. Set `base_url`, `api_key_env` and
`model` in the `openai_compatible` map in `config/config.exs` (it ships set up
for OpenRouter), export the key, and pick the backend for the run:

```
export OPENROUTER_API_KEY=sk-or-...
QUICKSILVER_BACKEND=openai_compatible mix run start_chat.exs
```

`api_key_env` is the *name* of the env var; keep the key itself out of the
config file. Set it to `nil` for local servers without auth (Ollama, vLLM, LM
Studio). Errors come back as `{:http_status, status, body}` with the
provider's message, or `{:missing_api_key, "ENV_VAR"}` if the key isn't set.

## Troubleshooting

- **Is the server up?** `curl http://127.0.0.1:8080/health` - `200` is ready,
  `503` is still loading, no connection means it isn't running.
- **Garbled output with `<|channel|>` / `<|start|>` tokens:** the model is being
  driven through the raw completion endpoint. Set `api: :chat`.
- **Model invents file contents instead of calling tools:** same cause - native
  tool calling needs `api: :chat` and `--jinja` on the server.
- See `TROUBLESHOOTING.md` for llama.cpp server issues.
