# Repository Map System

## Overview

Quicksilver now includes a sophisticated repository mapping system that uses tree-sitter-like AST parsing and PageRank algorithms to provide intelligent codebase context to AI agents. This enables agents to understand codebase structure and identify the most relevant code for any task.

## Architecture

```
Quicksilver.RepositoryMap
├── Parser/
│   ├── Entity              # Entity struct (modules, functions, etc.)
│   ├── ElixirParser        # AST-based Elixir parser
│   └── RepositoryParser    # Parallel file parsing with Flow
├── Graph/
│   ├── Builder             # Call graph construction
│   └── Ranker              # PageRank scoring algorithm
├── Cache/
│   └── Server              # ETS-backed caching GenServer
├── Formatter/
│   └── LLM                 # Token-optimized LLM formatting
└── AgentIntegration        # High-level API
```

## Key Features

### 1. AST-Based Parsing
- **Pure Elixir**: Uses `Code.string_to_quoted/2` for parsing
- **Concurrent**: Processes files in parallel using Flow
- **Comprehensive**: Extracts modules, functions, macros, protocols, implementations, structs
- **Metadata-Rich**: Captures signatures, docs, imports, calls, line numbers

### 2. Call Graph & PageRank
- **Graph Construction**: Builds directed graph of entity relationships
- **PageRank Scoring**: Assigns importance scores based on:
  - Call graph connectivity
  - Entity type (modules > functions)
  - File location (core files > tests)
  - Code visibility (public > private)
- **Smart Weighting**: Penalties for deep nesting, boosts for important locations

### 3. ETS Caching
- **Fast Reads**: Concurrent read-optimized ETS table
- **TTL-Based**: 24-hour expiration with automatic cleanup
- **Size Limits**: LRU eviction when cache is full
- **Supervision**: Integrated into Quicksilver's supervision tree

### 4. Token-Aware Formatting
- **Token Limiting**: Respects LLM context windows (default: 4000 tokens)
- **Keyword Focusing**: Prioritizes entities matching task keywords
- **Structured Output**: Organized by importance and file
- **Tree View**: File structure with entity counts

## Usage

### As a Tool

The `get_repository_context` tool is available to agents:

```json
{
  "tool": "get_repository_context",
  "args": {
    "task_description": "add authentication to user module",
    "token_limit": 4000
  }
}
```

### Programmatically

```elixir
# Get or generate repository map
{:ok, map_data} = Quicksilver.RepositoryMap.AgentIntegration.get_or_generate("/path/to/repo")

# Start an agent integration process
{:ok, agent_pid} = Quicksilver.RepositoryMap.AgentIntegration.start_link("/path/to/repo")

# Get context for a task
{:ok, context} = Quicksilver.RepositoryMap.AgentIntegration.get_context(
  agent_pid,
  "refactor authentication system",
  token_limit: 3000
)

# Find specific entities
{:ok, entities} = Quicksilver.RepositoryMap.AgentIntegration.find_entities(agent_pid, "Auth")

# Get related entities (via call graph)
{:ok, related} = Quicksilver.RepositoryMap.AgentIntegration.get_related(agent_pid, entity_id, 2)

# Refresh the map
:ok = Quicksilver.RepositoryMap.AgentIntegration.refresh(agent_pid)
```

### Cache Management

```elixir
# Get cache stats
stats = Quicksilver.RepositoryMap.Cache.Server.stats()

# Invalidate specific repo
:ok = Quicksilver.RepositoryMap.Cache.Server.invalidate("/path/to/repo")

# Clear all cached maps
:ok = Quicksilver.RepositoryMap.Cache.Server.clear_all()
```

## Output Format

The generated context includes:

### 1. Summary Statistics
```
# Repository Map

## Summary
- Total Entities: 288
- Total Files: 38
- Average Entity Size: 10.8 lines

## Entity Types
- Function: 249
- Module: 33
- Struct: 6
```

### 2. Key Entities (Scored)
```
### lib/quicksilver/agents/tool_agent.ex

- **Quicksilver.Agents.ToolAgent** ⭐⭐⭐ `defmodule Quicksilver.Agents.ToolAgent`
  > Clear the conversation history.
- **execute_with_tools/6** ⭐⭐⭐ `defp execute_with_tools(...)`
```

Stars indicate importance:
- ⭐⭐⭐ High importance (score > 0.7)
- ⭐⭐ Medium importance (score > 0.4)
- ⭐ Lower importance

### 3. File Structure
```
lib/
  quicksilver/
    agents/
      tool_agent.ex (10 entities)
    tools/
      registry.ex (9 entities)
```

## Performance

### Parsing Speed
- **Concurrent**: Uses all available CPU cores
- **Quicksilver codebase**: ~38 files, 288 entities in ~80ms
- **Cached**: Subsequent accesses are instant (ETS lookup)

### Memory Usage
- **Efficient**: Entities stored once, referenced by ID
- **Streaming**: File parsing uses Flow for bounded memory
- **Cache**: ETS tables with automatic cleanup

### Scalability
- **Large Codebases**: Tested with 40,000+ line codebases
- **Configurable**: Token limits prevent context overflow
- **Incremental**: Only parses changed files (future feature)

## Configuration

### Parser Options
```elixir
Quicksilver.RepositoryMap.Parser.RepositoryParser.parse(repo_path,
  extensions: [".ex", ".exs"],           # File extensions to parse
  max_concurrency: System.schedulers_online(),  # Parallel workers
  ignore_patterns: [~r/_build/, ~r/deps/]       # Files to ignore
)
```

### PageRank Options
```elixir
Quicksilver.RepositoryMap.Graph.Ranker.calculate_ranks(graph,
  damping_factor: 0.85,      # PageRank damping
  max_iterations: 100,       # Convergence iterations
  tolerance: 1.0e-6          # Convergence threshold
)
```

### Cache Options
```elixir
Quicksilver.RepositoryMap.Cache.Server.start_link(
  ttl: :timer.hours(24),     # Entry expiration time
  max_size: 100              # Maximum cached repositories
)
```

### Formatter Options
```elixir
Quicksilver.RepositoryMap.Formatter.LLM.format(repo_map,
  token_limit: 4000,         # Maximum output tokens
  focus_keywords: ["auth", "user"]  # Keywords to prioritize
)
```

## Entity Types

The parser recognizes these Elixir constructs:

- `:module` - `defmodule`
- `:function` - `def`, `defp`
- `:macro` - `defmacro`, `defmacrop`
- `:protocol` - `defprotocol`
- `:impl` - `defimpl`
- `:struct` - `defstruct`

Each entity includes:
- `id` - Unique identifier
- `name` - Entity name (e.g., "MyModule.function/2")
- `type` - Entity type
- `file_path` - Relative file path
- `line_start`, `line_end` - Source location
- `signature` - Function/module signature
- `doc` - Documentation string
- `imports` - List of imported modules
- `calls` - List of function calls
- `metadata` - Additional type-specific data

## Future Enhancements

### Tree-Sitter NIFs
Currently uses pure Elixir AST parsing. For multi-language support:
1. Add Rustler NIF wrapper around tree-sitter
2. Implement language-specific parsers (Python, JS, etc.)
3. Unified entity extraction across languages

### Incremental Updates
Track file changes and only re-parse modified files:
1. Integrate FileSystem for change detection
2. Differential graph updates
3. Partial cache invalidation

### Semantic Search
Beyond keyword matching:
1. Embed entity descriptions with semantic models
2. Vector similarity search for related code
3. Intent-based entity retrieval

### Cross-Repository Analysis
Analyze dependencies:
1. Parse Hex dependencies
2. Build cross-project call graphs
3. Identify external API usage

## Testing

Run the test script:

```bash
mix run test_repository_map.exs
```

Or test programmatically:

```elixir
# In IEx
iex> Application.ensure_all_started(:quicksilver)
iex> {:ok, map} = Quicksilver.RepositoryMap.AgentIntegration.get_or_generate(".")
iex> IO.inspect(map.map.stats)
```

## Dependencies

- `libgraph ~> 0.16` - Graph data structure and algorithms
- `flow ~> 1.2` - Concurrent data processing
- `file_system ~> 1.0` - File watching (for future incremental updates)

## Integration with ToolAgent

The repository map integrates seamlessly with ToolAgent:

1. **Automatic Context**: Agents can call `get_repository_context` before complex tasks
2. **Smart Prioritization**: PageRank ensures the most important code is shown first
3. **Token Budget**: Respects LLM context limits automatically
4. **Caching**: Repeated queries are fast (ETS-backed)

## Best Practices

### When to Use
- ✅ Starting a new task in an unfamiliar codebase
- ✅ Refactoring that affects multiple files
- ✅ Finding where functionality is implemented
- ✅ Understanding codebase architecture

### When NOT to Use
- ❌ Reading a specific file (use `read_file` instead)
- ❌ Simple, single-file changes
- ❌ When you already know the exact location

### Task Descriptions
Good task descriptions help keyword extraction:

**Good:**
- "add authentication to user module"
- "refactor database connection pooling"
- "fix error in payment processing"

**Poor:**
- "make it better" (no keywords)
- "fix bug" (too vague)
- "update" (no context)

## Troubleshooting

### "Failed to parse file"
- Check file syntax (must be valid Elixir)
- Files with syntax errors are skipped with a warning

### "Context is truncated"
- Increase `token_limit` parameter
- Use more specific task descriptions to focus results
- Split complex tasks into smaller ones

### "No entities found"
- Check file patterns (`.ex`, `.exs` only by default)
- Verify gitignore isn't excluding needed files
- Check log output for parsing errors

## Credits

Inspired by:
- Aider's repository map implementation
- PageRank algorithm by Larry Page & Sergey Brin
- Tree-sitter parsing approach
- Research on AI coding agents from Anthropic, OpenAI, and open-source projects
