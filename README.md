# Quicksilver

🧪 Quicksilver – The Alchemical Agentic Framework for Elixir

Quicksilver is an Elixir-native AI sidekick framework for building intelligent, modular agents powered by local and remote LLMs. Designed for hackers, researchers, and builders, Quicksilver lets you:

⚡ Run interchangeable agents with distinct personalities and goals
🧠 Plug into any LLM backend (e.g. llama.cpp, OpenAI, Together.ai)
🔮 Craft tools and memory systems your agents can use to reason and act
🚀 Harness Elixir's concurrency to orchestrate many agents at once
🦾 Stay in control — run powerful open models on your own GPU

Whether you're creating an autonomous research assistant, a conversational sidekick, or a multi-agent system, Quicksilver is your spellbook for building agentic intelligence in Elixir.

## Quick Start

### Start the Terminal Chat Interface

```bash
# Easiest way - start chatting immediately
mix run start_chat.exs
```

Or from IEx:
```elixir
iex -S mix
iex> Quicksilver.Interfaces.Terminal.start()
```

### Try These Commands

Once in the terminal:
- `tools` - See what the agent can do
- `agents` - List available agents
- `agent <name>` - Switch to a different agent
- `help` - Show all commands
- `exit` - Quit

### Example Questions

**File Operations:**
```
Read the mix.exs file
What dependencies does this project have?
Show me the contents of lib/quicksilver/tools/registry.ex
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
List all the modules in lib/quicksilver/tools/
```

## Features

### 🔧 Tool-Calling Agent

The **ToolAgent** can autonomously use tools to answer your questions:

- **read_file** - Read any file in the workspace
- **search_files** - Search the codebase with ripgrep/grep
- Iterative reasoning (up to 10 tool calls per task)
- Robust JSON parsing for various LLM formats

### 🤖 Multi-Agent System

Switch between specialized agents during a conversation:

```elixir
you> agents                    # List all agents
you> agent tool_agent          # Switch to tool agent
you> What tools do you have?   # Agent responds
```

History is preserved when switching agents.

### 🔌 Backend Abstraction

Works with any LLM backend:

```elixir
# Direct backend usage
{:ok, response} = Quicksilver.Backends.LlamaCpp.complete(
  LlamaCpp,
  [%{role: "user", content: "Hello!"}]
)

IO.puts(response)
```

## Testing

Run the test suite:

```bash
mix run test_tools.exs
```

This validates:
- Tool registration and listing
- File reading capability
- File searching capability
- End-to-end agent task execution

## Architecture

```
Terminal → Agent → Backend (LLM)
             ↓
          Tools
          (read_file, search_files)
```

### Adding New Agents

1. Create your agent module with `execute_task/3`
2. Add to supervision tree in `lib/application.ex`
3. Register in terminal's `@available_agents`

See `QUICKSILVER.md` for detailed architecture.

## Adding New Tools

1. Implement `Quicksilver.Tools.Behaviour`:
   ```elixir
   defmodule MyTool do
     @behaviour Quicksilver.Tools.Behaviour

     def name, do: "my_tool"
     def description, do: "Does something useful"
     def parameters_schema, do: %{...}
     def execute(args, context), do: {:ok, result}
   end
   ```

2. Register in `lib/quicksilver/tools.ex`

## Configuration

See `config/config.exs` for llama.cpp server settings:
- Model path and file
- Server port
- GPU layers
- Context size
- **auto_start** - Set to `true` to automatically load model on startup (defaults to `false`)

### Backend Management

Quicksilver provides flexible control over the LLM backend:

#### Manual Start (Default - Recommended)

By default, Quicksilver does NOT auto-start the server. This prevents unexpected resource usage:

```elixir
# config/config.exs
llama_cpp: %{
  auto_start: false  # or omit - defaults to false
}
```

#### Auto-Start

To automatically load the model on startup, set `auto_start: true`:

```elixir
# config/config.exs
llama_cpp: %{
  model_file: "Llama-3.3-70B-Instruct-Q4_K_M.gguf",
  auto_start: false  # Don't load model on startup
}
```

Then start the backend manually when ready:

**Option 1: Standalone Server (Recommended)**
```elixir
# Start server that persists across Quicksilver restarts
iex> Quicksilver.Backends.LlamaCpp.start_standalone()

# Later, when done:
iex> Quicksilver.Backends.LlamaCpp.stop_standalone()
```

**Option 2: Managed Server**
```elixir
# Server shuts down when Quicksilver exits
iex> Quicksilver.Backends.LlamaCpp.start_owned_server()
```

**Option 3: Auto-Initialize**
```elixir
# Connect to existing server or start new one
iex> Quicksilver.Backends.LlamaCpp.initialize()
```

#### Checking Server Status

```elixir
iex> Quicksilver.Backends.LlamaCpp.server_running?()
true

iex> Quicksilver.Backends.LlamaCpp.health_check(LlamaCpp)
:ok
```

## Project Status

✅ Tool-calling system working
✅ Multi-agent terminal interface
✅ Read and search tools implemented
✅ Full test coverage
✅ Production-ready architecture

## Troubleshooting

**"Backend not ready"** - Wait a few seconds for the llama.cpp server to finish loading the model

**No tool calls happening** - Check debug logs to see LLM output, try more explicit requests, some models are better at tool-calling than others

**Agent gives wrong answers** - Try `clear` command to reset history, rephrase your question more specifically

## Advanced Usage

### Direct API Access

Call the ToolAgent directly from Elixir code:

```elixir
{:ok, response} = Quicksilver.Agents.ToolAgent.execute_task(
  Quicksilver.Agents.ToolAgent,
  "What is this project about?",
  workspace_root: File.cwd!()
)

IO.puts(response)
```
