# Quicksilver

Ephemeral LLM conversation threads for Elixir.

Quicksilver provides ephemeral, tool-capable conversation threads powered by multiple LLM backends. The simplest conversation is a bare chat. Add tools and you get an iterative reasoning loop. Real "agents" — things with goals, directives, persistence — belong in a layer above.

- Create ephemeral conversations with optional tool-calling
- Multiple backends: local llama.cpp, OpenAI, Anthropic, Claude CLI
- Modular tools for file operations, code search, and repository analysis
- Elixir concurrency for parallel code parsing and PageRank analysis

## Quick Start

### Conversations

```elixir
# Bare chat — no tools, no system prompt
ctx = Quicksilver.Conversation.new()
{:ok, response, ctx} = Quicksilver.Conversation.send(ctx, "Hello!")
{:ok, response, ctx} = Quicksilver.Conversation.send(ctx, "Tell me more")

# Different backends
ctx = Quicksilver.Conversation.new(backend: :openai)
ctx = Quicksilver.Conversation.new(backend: :anthropic)
ctx = Quicksilver.Conversation.new(backend: :claude_cli)

# Chat with a system prompt
ctx = Quicksilver.Conversation.new(system_prompt: "You are an Elixir expert.")
{:ok, response, ctx} = Quicksilver.Conversation.send(ctx, "What is GenServer?")

# Tool-calling conversation (iterative reasoning loop)
ctx = Quicksilver.Conversation.new(
  tools: :all,
  workspace_root: File.cwd!()
)
{:ok, response, ctx} = Quicksilver.Conversation.send(ctx, "Read mix.exs")

# Selective tools
ctx = Quicksilver.Conversation.new(tools: ["read_file", "search_files"])

# History management
Quicksilver.Conversation.history(ctx)   # => [%{role: "user", ...}, ...]
ctx = Quicksilver.Conversation.clear(ctx)  # clear history, keep config
```

### Terminal Chat Interface

```bash
mix run start_chat.exs
```

Or from IEx:
```elixir
iex -S mix
iex> Quicksilver.chat()
iex> Quicksilver.chat(backend: :openai, tools: :none)
```

Commands: `tools`, `help`, `history`, `clear`, `exit`

## Architecture

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
  - Multiple providers
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
├── Quicksilver.Tools.Registry (GenServer)
└── Quicksilver.Tools.RepositoryMap.Cache.Server (GenServer)
```

Conversations are structs — no processes, no supervision needed.

## Backends

| Key | Module | Type |
|-----|--------|------|
| `:llama_cpp` | `Quicksilver.LlmEngine.Backends.LlamaCpp` | Local llama.cpp (GenServer) |
| `:openai` | `Quicksilver.LlmEngine.Backends.OpenAI` | OpenAI API (stateless) |
| `:anthropic` | `Quicksilver.LlmEngine.Backends.Anthropic` | Anthropic API (stateless) |
| `:claude_cli` | `Quicksilver.LlmEngine.Backends.ClaudeCli` | Claude CLI headless (stateful) |

## Tools

**Read-only:**
- `read_file` - Read any file in the workspace
- `search_files` - Search the codebase with ripgrep/grep
- `list_files` - List files with glob patterns
- `get_repository_context` - PageRank-based code analysis
- `run_tests` - Run mix test

**Write (require approval):**
- `create_file` / `edit_file` - Create and edit files

### Adding New Tools

1. Implement `Quicksilver.Tools.Behaviour`:
   ```elixir
   defmodule Quicksilver.Tools.MyTool do
     @behaviour Quicksilver.Tools.Behaviour

     def name, do: "my_tool"
     def description, do: "Does something useful"
     def parameters_schema, do: %{...}
     def execute(args, context), do: {:ok, result}
   end
   ```

2. Register in `lib/quicksilver/tools/tools.ex` `register_default_tools/0`

## Configuration

```elixir
# config/config.exs

# Local LlamaCpp
config :quicksilver, Quicksilver.LlmEngine.Backends.LlamaCpp,
  server_path: "/path/to/llama-server",
  model_path: "/path/to/models/",
  model_file: "model.gguf",
  port: 8080,
  threads: 16,
  ctx_size: 8192,
  gpu_layers: 99,
  auto_start: true

# OpenAI
config :quicksilver, Quicksilver.LlmEngine.Backends.OpenAI,
  api_key: System.get_env("OPENAI_API_KEY"),
  model: "gpt-4o"

# Anthropic
config :quicksilver, Quicksilver.LlmEngine.Backends.Anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-sonnet-4-6"
```

## API Reference

```elixir
# Conversations
ctx = Quicksilver.Conversation.new(opts)
{:ok, response, ctx} = Quicksilver.Conversation.send(ctx, message)
Quicksilver.Conversation.history(ctx)
Quicksilver.Conversation.clear(ctx)

# Terminal
Quicksilver.chat()
Quicksilver.chat(backend: :openai, tools: :none)

# LLM Engine
Quicksilver.LlmEngine.complete(messages, backend: :openai)
Quicksilver.LlmEngine.health_check(backend: :llama_cpp)

# Tools
Quicksilver.list_tools()
Quicksilver.register_tool(module)
Quicksilver.execute_tool(name, args, context)
```

## Testing

```bash
mix test
```

## Troubleshooting

**"Backend not ready"** - Wait a few seconds for the llama.cpp server to finish loading the model

**No tool calls happening** - Check debug logs to see LLM output, try more explicit requests

**Wrong answers** - Try `clear` command to reset history, rephrase your question
