# Quicksilver

Quicksilver – The Alchemical Agentic Framework for Elixir

Quicksilver is an Elixir-native AI sidekick framework for building intelligent, modular agents powered by local LLMs. Designed for hackers, researchers, and builders, Quicksilver lets you:

- Run a stateless tool-calling agent with iterative reasoning
- Plug into any LLM backend (currently llama.cpp, extensible via behaviour)
- Use modular tools for file operations, code search, and repository analysis
- Harness Elixir's concurrency for parallel code parsing and PageRank analysis
- Stay in control — run powerful open models on your own GPU

## Quick Start

### Start the Terminal Chat Interface

```bash
# Easiest way - start chatting immediately
mix run start_chat.exs
```

Or from IEx:
```elixir
iex -S mix
iex> Quicksilver.chat()
```

### Try These Commands

Once in the terminal:
- `tools` - See what the agent can do
- `help` - Show all commands
- `exit` - Quit

### Example Questions

**File Operations:**
```
Read the mix.exs file
What dependencies does this project have?
Show me the contents of lib/agentic/tools/registry.ex
```

**Search Operations:**
```
Search for defmodule in the codebase
Find all files with "GenServer" in them
Search for the word "tool" in .ex files
```

**Analysis:**
```
What is this project about?
What are the main components of this project?
List all the modules in lib/agentic/tools/
```

## Architecture

Quicksilver is organized into two independent layers:

1. **LLM Engine** (`lib/llm_engine/`) — standalone local LLM server management
2. **Agentic** (`lib/agentic/`) — agents, tools, approval, repository map, and interfaces

```
Terminal → Stateless Agent → LLM Backend
                ↓
             Tools
             (read_file, search_files, edit_file, ...)
```

The agent is stateless — the terminal manages conversation history. No agent processes in the supervision tree.

## Features

### Tool-Calling Agent

The stateless **Agent** can autonomously use tools to answer your questions:

- **read_file** - Read any file in the workspace
- **search_files** - Search the codebase with ripgrep/grep
- **list_files** - List files with glob patterns
- **create_file** / **edit_file** - Create and edit files (with approval)
- **run_tests** - Run mix test
- **get_repository_context** - PageRank-based code analysis
- Iterative reasoning (up to 50 tool calls per task)
- Robust JSON parsing for various LLM formats

### Backend Abstraction

Works with any LLM backend:

```elixir
# Via the LLM Engine facade
{:ok, response} = Quicksilver.LlmEngine.complete(
  [%{role: "user", content: "Hello!"}]
)

# Direct backend usage
{:ok, response} = Quicksilver.LlmEngine.Backends.LlamaCpp.complete(
  Quicksilver.LlmEngine.Backends.LlamaCpp,
  [%{role: "user", content: "Hello!"}]
)
```

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
# Start standalone server (persists across app restarts)
Quicksilver.LlmEngine.Backends.LlamaCpp.start_standalone()

# Check status
Quicksilver.LlmEngine.Backends.LlamaCpp.server_running?()
Quicksilver.LlmEngine.health_check()

# Stop standalone server
Quicksilver.LlmEngine.Backends.LlamaCpp.stop_standalone()
```

## Testing

```bash
mix test    # All tests
```

## Advanced Usage

### Direct API Access

Call the agent directly from Elixir code:

```elixir
{:ok, response, _history} = Quicksilver.Agentic.execute_task(
  "What is this project about?",
  workspace_root: File.cwd!()
)

IO.puts(response)
```

## Troubleshooting

**"Backend not ready"** - Wait a few seconds for the llama.cpp server to finish loading the model

**No tool calls happening** - Check debug logs to see LLM output, try more explicit requests

**Agent gives wrong answers** - Try `clear` command to reset history, rephrase your question
