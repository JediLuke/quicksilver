# Quicksilver

Quicksilver – Ephemeral LLM Conversation Threads for Elixir

Quicksilver provides ephemeral, tool-capable conversation threads powered by local LLMs. The simplest conversation is a bare chat. Add tools and you get an iterative reasoning loop. Real "agents" — things with goals, directives, persistence — belong in a layer above.

- Create ephemeral conversation threads with optional tool-calling
- Plug into any LLM backend (currently llama.cpp, extensible via behaviour)
- Use modular tools for file operations, code search, and repository analysis
- Harness Elixir's concurrency for parallel code parsing and PageRank analysis
- Stay in control — run powerful open models on your own GPU

## Quick Start

### Conversations

```elixir
# Bare chat — no tools, no system prompt
conv = Quicksilver.new_conversation()
{:ok, response, conv} = Quicksilver.Conversation.send(conv, "Hello!")
{:ok, response, conv} = Quicksilver.Conversation.send(conv, "Tell me more")

# Chat with a system prompt
conv = Quicksilver.new_conversation(system_prompt: "You are an Elixir expert.")
{:ok, response, conv} = Quicksilver.Conversation.send(conv, "What is GenServer?")

# Tool-calling conversation (iterative reasoning loop)
conv = Quicksilver.new_conversation(
  tools: :all,
  workspace_root: File.cwd!()
)
{:ok, response, conv} = Quicksilver.Conversation.send(conv, "Read mix.exs")

# Selective tools
conv = Quicksilver.new_conversation(tools: ["read_file", "search_files"])

# History management
Quicksilver.Conversation.history(conv)  # => [%{role: "user", ...}, ...]
conv = Quicksilver.Conversation.clear(conv)  # clear history, keep config
```

### Terminal Chat Interface

```bash
mix run start_chat.exs
```

Or from IEx:
```elixir
iex -S mix
iex> Quicksilver.chat()
```

Commands: `tools`, `help`, `history`, `clear`, `exit`

## Architecture

Quicksilver is organized into three layers:

```
Layer Above (your code)
  - Goals, directives, persistence
  - Owns one or more Conversations
          |
          v
Quicksilver.Conversation (struct, not process)
  - Ephemeral message thread
  - Optional tool-calling loop
  - No persistence, no goals
          |
          v
Quicksilver.LlmEngine
  - Backend-agnostic completions
  - Server lifecycle management
```

| Concern | Quicksilver | Layer Above |
|---------|-------------|-------------|
| LLM calls | Yes | No (uses Quicksilver) |
| Message history | In-memory, ephemeral | Persists to disk/DB |
| Tool execution | Yes | Registers custom tools |
| Conversation threads | Creates and manages | Owns one or more |
| Goals / directives | No | Yes |
| Long-term memory | No | Yes |

### Supervision Tree

```elixir
Quicksilver.Application
├── Quicksilver.LlmEngine.Backends.LlamaCpp (GenServer)
├── Quicksilver.Agentic.Tools.Registry (GenServer)
└── Quicksilver.Agentic.RepositoryMap.Cache.Server (GenServer)
```

Conversations are structs — no processes, no supervision needed.

## Tools

**Read-only (auto-approved):**
- `read_file` - Read any file in the workspace
- `search_files` - Search the codebase with ripgrep/grep
- `list_files` - List files with glob patterns
- `get_repository_context` - PageRank-based code analysis
- `run_tests` - Run mix test

**Write (require approval):**
- `create_file` / `edit_file` - Create and edit files

## Adding New Tools

1. Implement `Quicksilver.Agentic.Tools.Behaviour`:
   ```elixir
   defmodule Quicksilver.Agentic.Tools.MyTool do
     @behaviour Quicksilver.Agentic.Tools.Behaviour

     def name, do: "my_tool"
     def description, do: "Does something useful"
     def parameters_schema, do: %{...}
     def execute(args, context), do: {:ok, result}
   end
   ```

2. Register in `lib/agentic/tools.ex` `register_default_tools/0`

## Configuration

See `config/config.exs` for llama.cpp server settings:

```elixir
config :quicksilver, Quicksilver.LlmEngine.Backends.LlamaCpp,
  server_path: "/path/to/llama-server",
  model_path: "/path/to/models/",
  model_file: "model.gguf",
  port: 8080,
  threads: 16,
  ctx_size: 8192,
  gpu_layers: 99,
  auto_start: true
```

### Backend Management

```elixir
Quicksilver.LlmEngine.Backends.LlamaCpp.start_standalone()
Quicksilver.LlmEngine.Backends.LlamaCpp.server_running?()
Quicksilver.LlmEngine.health_check()
Quicksilver.LlmEngine.Backends.LlamaCpp.stop_standalone()
```

## API Reference

```elixir
# Conversations
conv = Quicksilver.new_conversation(opts)
{:ok, response, conv} = Quicksilver.Conversation.send(conv, message)
Quicksilver.Conversation.history(conv)
Quicksilver.Conversation.clear(conv)

# Terminal
Quicksilver.chat()

# LLM Engine
Quicksilver.LlmEngine.complete(messages, opts)
Quicksilver.LlmEngine.health_check()

# Tools
Quicksilver.Agentic.list_tools()
Quicksilver.Agentic.register_tool(module)
Quicksilver.Agentic.execute_tool(name, args, context)
```

## Testing

```bash
mix test
```

## Troubleshooting

**"Backend not ready"** - Wait a few seconds for the llama.cpp server to finish loading the model

**No tool calls happening** - Check debug logs to see LLM output, try more explicit requests

**Agent gives wrong answers** - Try `clear` command to reset history, rephrase your question
