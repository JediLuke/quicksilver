# Quicksilver Minimal Tool-Calling Agent Implementation

**Goal:** Get a working tool-calling agent in Quicksilver that can read files and search codebases using grep. This is the absolute minimum to prove the concept works.

## File Structure
```
lib/quicksilver/
├── tools/
│   ├── behaviour.ex
│   ├── registry.ex
│   ├── formatter.ex
│   ├── file_reader.ex
│   └── search_files.ex
├── agents/
│   └── tool_agent.ex
└── tools.ex  # Main module
```

## Step 1: Core Tool Infrastructure

### `lib/quicksilver/tools/behaviour.ex`
```elixir
defmodule Quicksilver.Tools.Behaviour do
  @moduledoc """
  Behaviour that all tools must implement.
  """
  
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters_schema() :: map()
  @callback execute(args :: map(), context :: map()) :: 
    {:ok, String.t()} | {:error, String.t()}
end
```

### `lib/quicksilver/tools/registry.ex`
```elixir
defmodule Quicksilver.Tools.Registry do
  @moduledoc """
  Registry for available tools. Manages tool discovery and access.
  """
  use GenServer
  
  # Client API
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put(opts, :name, __MODULE__))
  end
  
  def register(tool_module) when is_atom(tool_module) do
    GenServer.call(__MODULE__, {:register, tool_module})
  end
  
  def get_tool(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:get_tool, name})
  end
  
  def list_tools() do
    GenServer.call(__MODULE__, :list_tools)
  end
  
  def list_tools_json() do
    list_tools() |> Jason.encode!()
  end
  
  def execute_tool(name, args, context \\ %{}) do
    case get_tool(name) do
      nil -> 
        {:error, "Tool '#{name}' not found"}
      tool_module ->
        tool_module.execute(args, context)
    end
  end
  
  # Server Callbacks
  
  @impl true
  def init(_opts) do
    {:ok, %{tools: %{}}}
  end
  
  @impl true
  def handle_call({:register, tool_module}, _from, state) do
    if tool_behaviour?(tool_module) do
      name = tool_module.name()
      new_tools = Map.put(state.tools, name, tool_module)
      {:reply, :ok, %{state | tools: new_tools}}
    else
      {:reply, {:error, "Module does not implement Tools.Behaviour"}, state}
    end
  end
  
  @impl true
  def handle_call({:get_tool, name}, _from, state) do
    {:reply, Map.get(state.tools, name), state}
  end
  
  @impl true
  def handle_call(:list_tools, _from, state) do
    tools_list = state.tools
    |> Map.values()
    |> Enum.map(fn module ->
      %{
        "name" => module.name(),
        "description" => module.description(),
        "parameters" => module.parameters_schema()
      }
    end)
    {:reply, tools_list, state}
  end
  
  defp tool_behaviour?(module) do
    Code.ensure_loaded?(module) and
    function_exported?(module, :name, 0) and
    function_exported?(module, :execute, 2)
  end
end
```

### `lib/quicksilver/tools/formatter.ex`
```elixir
defmodule Quicksilver.Tools.Formatter do
  @moduledoc """
  Formats tool calls for llama.cpp and parses responses.
  Handles multiple formats that different models might use.
  """
  
  def system_prompt_with_tools(tools) do
    tools_json = tools 
    |> Enum.map(&tool_to_json/1)
    |> Jason.encode!(pretty: true)
    
    """
    You are a helpful AI assistant with access to tools.
    
    Available tools:
    #{tools_json}
    
    To use a tool, respond with ONLY a JSON object in this exact format:
    {"tool_name": "name_here", "arguments": {"arg1": "value1", "arg2": "value2"}}
    
    After receiving tool results, incorporate them into your response.
    If you don't need to use a tool, respond normally without JSON.
    """
  end
  
  def parse_tool_call(response) do
    # Try to extract JSON from the response
    cond do
      # Direct JSON response
      valid_json?(response) ->
        parse_json_tool_call(response)
      
      # JSON embedded in text (look for {...})
      json_match = extract_json_block(response) ->
        parse_json_tool_call(json_match)
      
      # No tool call found
      true ->
        {:text_response, response}
    end
  end
  
  defp tool_to_json(tool_module) do
    %{
      "name" => tool_module.name(),
      "description" => tool_module.description(),
      "parameters" => tool_module.parameters_schema()
    }
  end
  
  defp valid_json?(text) do
    case Jason.decode(text) do
      {:ok, _} -> true
      _ -> false
    end
  end
  
  defp extract_json_block(text) do
    case Regex.run(~r/\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}/, text) do
      [json] -> json
      _ -> nil
    end
  end
  
  defp parse_json_tool_call(json_str) do
    case Jason.decode(json_str) do
      {:ok, %{"tool_name" => name, "arguments" => args}} ->
        {:tool_call, name, args}
      {:ok, %{"name" => name, "arguments" => args}} ->
        {:tool_call, name, args}
      _ ->
        {:error, "Invalid tool call format"}
    end
  end
end
```

## Step 2: Implement Two Basic Tools

### `lib/quicksilver/tools/file_reader.ex`
```elixir
defmodule Quicksilver.Tools.FileReader do
  @moduledoc """
  Tool for reading file contents. Read-only and safe.
  """
  @behaviour Quicksilver.Tools.Behaviour
  
  @impl true
  def name(), do: "read_file"
  
  @impl true
  def description() do
    "Read the contents of a file. Returns the file content as text."
  end
  
  @impl true
  def parameters_schema() do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path to the file to read (relative or absolute)"
        }
      },
      "required" => ["path"]
    }
  end
  
  @impl true
  def execute(%{"path" => path}, context) do
    # Optionally restrict to workspace
    safe_path = resolve_path(path, context)
    
    case File.read(safe_path) do
      {:ok, content} ->
        # Truncate if too large (optional)
        content = if byte_size(content) > 50_000 do
          String.slice(content, 0, 50_000) <> "\n\n[... truncated ...]"
        else
          content
        end
        {:ok, content}
        
      {:error, :enoent} ->
        {:error, "File not found: #{path}"}
      {:error, reason} ->
        {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end
  
  defp resolve_path(path, context) do
    workspace = context[:workspace_root] || File.cwd!()
    
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path, workspace)
    end
  end
end
```

### `lib/quicksilver/tools/search_files.ex`
```elixir
defmodule Quicksilver.Tools.SearchFiles do
  @moduledoc """
  Search for patterns in files using grep or ripgrep.
  Falls back to Elixir implementation if external tools unavailable.
  """
  @behaviour Quicksilver.Tools.Behaviour
  
  @impl true
  def name(), do: "search_files"
  
  @impl true
  def description() do
    "Search for text patterns in files within a directory"
  end
  
  @impl true
  def parameters_schema() do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Text pattern to search for"
        },
        "directory" => %{
          "type" => "string",
          "description" => "Directory to search in (default: current directory)"
        },
        "file_pattern" => %{
          "type" => "string",
          "description" => "File pattern to match (e.g., '*.ex' for Elixir files)"
        }
      },
      "required" => ["pattern"]
    }
  end
  
  @impl true
  def execute(args, context) do
    pattern = args["pattern"]
    directory = args["directory"] || context[:workspace_root] || "."
    file_pattern = args["file_pattern"] || "*"
    
    # Try ripgrep first, then grep, then Elixir fallback
    result = cond do
      command_available?("rg") ->
        search_with_ripgrep(pattern, directory, file_pattern)
      command_available?("grep") ->
        search_with_grep(pattern, directory, file_pattern)
      true ->
        search_with_elixir(pattern, directory, file_pattern)
    end
    
    case result do
      {:ok, matches} when matches == [] ->
        {:ok, "No matches found"}
      {:ok, matches} ->
        {:ok, format_results(matches)}
      error ->
        error
    end
  end
  
  defp command_available?(cmd) do
    case System.find_executable(cmd) do
      nil -> false
      _ -> true
    end
  end
  
  defp search_with_ripgrep(pattern, directory, file_pattern) do
    # Build ripgrep command
    args = [pattern, directory, "--type-add", "custom:#{file_pattern}"]
    
    case System.cmd("rg", args, stderr_to_stdout: true) do
      {output, 0} ->
        matches = output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_grep_line/1)
        |> Enum.reject(&is_nil/1)
        {:ok, matches}
      {_, _} ->
        {:ok, []}  # No matches found
    end
  end
  
  defp search_with_grep(pattern, directory, file_pattern) do
    # Find files and grep them
    find_cmd = "find #{directory} -name '#{file_pattern}' -type f"
    
    case System.cmd("sh", ["-c", find_cmd]) do
      {files_output, 0} ->
        files = String.split(files_output, "\n", trim: true)
        
        matches = files
        |> Enum.flat_map(fn file ->
          case System.cmd("grep", ["-n", pattern, file], stderr_to_stdout: true) do
            {output, 0} ->
              output
              |> String.split("\n", trim: true)
              |> Enum.map(fn line -> {file, line} end)
            _ ->
              []
          end
        end)
        |> Enum.map(fn {file, line} -> 
          %{file: file, match: line}
        end)
        
        {:ok, matches}
      _ ->
        {:error, "Failed to search files"}
    end
  end
  
  defp search_with_elixir(pattern, directory, file_pattern) do
    # Pure Elixir fallback
    pattern_regex = Regex.compile!(pattern, "i")
    
    matches = Path.wildcard(Path.join(directory, "**", file_pattern))
    |> Enum.flat_map(fn file ->
      case File.read(file) do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} -> 
            Regex.match?(pattern_regex, line)
          end)
          |> Enum.map(fn {line, line_no} ->
            %{
              file: file,
              line: line_no,
              match: String.trim(line)
            }
          end)
        _ ->
          []
      end
    end)
    |> Enum.take(100)  # Limit results
    
    {:ok, matches}
  end
  
  defp parse_grep_line(line) do
    case String.split(line, ":", parts: 3) do
      [file, line_no, content] ->
        %{
          file: file,
          line: String.to_integer(line_no),
          match: String.trim(content)
        }
      _ ->
        nil
    end
  end
  
  defp format_results(matches) do
    matches
    |> Enum.take(20)  # Limit to 20 results
    |> Enum.map(fn match ->
      case match do
        %{file: file, line: line, match: content} ->
          "#{file}:#{line}: #{content}"
        %{file: file, match: content} ->
          "#{file}: #{content}"
        _ ->
          inspect(match)
      end
    end)
    |> Enum.join("\n")
  end
end
```

## Step 3: Backend Behaviour

### `lib/quicksilver/backends/behaviour.ex`
```elixir
defmodule Quicksilver.Backends.Behaviour do
  @moduledoc """
  Behaviour for LLM backends. Allows the tool agent to work with any LLM backend.
  """

  @callback completion(prompt :: String.t(), opts :: keyword()) ::
    {:ok, String.t()} | {:error, String.t()}
end
```

## Step 4: The Tool Agent

### `lib/quicksilver/agents/tool_agent.ex`
```elixir
defmodule Quicksilver.Agents.ToolAgent do
  @moduledoc """
  Agent that can use tools to accomplish tasks.
  Works with any backend implementing Quicksilver.Backends.Behaviour.
  """
  use GenServer
  require Logger

  defstruct [
    :backend_module,
    :tools_registry,
    :max_iterations,
    :conversation_history
  ]
  
  # Client API
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end
  
  def execute_task(agent \\ __MODULE__, task) do
    GenServer.call(agent, {:execute_task, task}, :infinity)
  end
  
  # Server Callbacks
  
  @impl true
  def init(opts) do
    backend = opts[:backend_module] || raise("backend_module required")

    # Verify the backend implements the behaviour
    unless function_exported?(backend, :completion, 2) do
      raise "Backend #{backend} must implement Quicksilver.Backends.Behaviour"
    end

    state = %__MODULE__{
      backend_module: backend,
      tools_registry: opts[:tools_registry] || Quicksilver.Tools.Registry,
      max_iterations: opts[:max_iterations] || 5,
      conversation_history: []
    }

    {:ok, state}
  end
  
  @impl true
  def handle_call({:execute_task, task}, _from, state) do
    Logger.info("Starting task: #{task}")
    
    # Reset conversation history for new task
    state = %{state | conversation_history: []}
    
    # Execute the task with tool support
    result = execute_with_tools(task, state, 0)
    
    {:reply, result, state}
  end
  
  # Private Functions
  
  defp execute_with_tools(task, state, iteration) when iteration >= state.max_iterations do
    {:error, "Max iterations reached"}
  end
  
  defp execute_with_tools(task, state, iteration) do
    Logger.debug("Iteration #{iteration + 1}")
    
    # Get available tools
    tools = Quicksilver.Tools.Registry.list_tools()
    
    # Build the prompt with tools
    prompt = build_prompt(task, tools, state.conversation_history)
    
    # Call the LLM
    Logger.debug("Calling LLM with prompt")
    case state.backend_module.completion(prompt, max_tokens: 500) do
      {:ok, response} ->
        Logger.debug("LLM response: #{String.slice(response, 0, 200)}")
        
        # Parse the response
        case Quicksilver.Tools.Formatter.parse_tool_call(response) do
          {:tool_call, tool_name, args} ->
            Logger.info("Tool call detected: #{tool_name}")
            handle_tool_call(tool_name, args, task, state, iteration)
            
          {:text_response, text} ->
            Logger.info("Final response received")
            {:ok, text}
            
          {:error, reason} ->
            Logger.error("Failed to parse response: #{reason}")
            {:error, reason}
        end
        
      {:error, reason} ->
        Logger.error("LLM call failed: #{reason}")
        {:error, reason}
    end
  end
  
  defp handle_tool_call(tool_name, args, task, state, iteration) do
    # Execute the tool
    Logger.info("Executing tool: #{tool_name} with args: #{inspect(args)}")
    
    result = Quicksilver.Tools.Registry.execute_tool(tool_name, args)
    
    # Add to conversation history
    tool_result_text = case result do
      {:ok, output} -> 
        "Tool '#{tool_name}' returned:\n#{output}"
      {:error, error} -> 
        "Tool '#{tool_name}' failed: #{error}"
    end
    
    updated_history = state.conversation_history ++ [
      %{role: "assistant", content: "Using tool: #{tool_name}"},
      %{role: "tool", content: tool_result_text}
    ]
    
    # Continue with updated context
    updated_state = %{state | conversation_history: updated_history}
    execute_with_tools(task, updated_state, iteration + 1)
  end
  
  defp build_prompt(task, tools, history) do
    # System prompt with tools
    system = Quicksilver.Tools.Formatter.system_prompt_with_tools(tools)
    
    # Build conversation
    conversation = history
    |> Enum.map(fn 
      %{role: "assistant", content: content} -> "Assistant: #{content}"
      %{role: "tool", content: content} -> "Tool Result: #{content}"
      %{role: "user", content: content} -> "User: #{content}"
    end)
    |> Enum.join("\n\n")
    
    # Combine everything
    """
    #{system}
    
    #{conversation}
    
    User: #{task}
    
    Assistant: 
    """
  end
end
```

## Step 5: Main Module and Startup

### `lib/quicksilver/tools.ex`
```elixir
defmodule Quicksilver.Tools do
  @moduledoc """
  Main entry point for the tools system.
  """
  
  def register_default_tools() do
    tools = [
      Quicksilver.Tools.FileReader,
      Quicksilver.Tools.SearchFiles
    ]
    
    Enum.each(tools, fn tool ->
      Quicksilver.Tools.Registry.register(tool)
    end)
    
    :ok
  end
end
```

## Step 6: Add to Your Application Supervisor

### In `lib/quicksilver/application.ex`
```elixir
defmodule Quicksilver.Application do
  use Application
  
  def start(_type, _args) do
    children = [
      # ... your existing children ...
      
      # Add the tools registry
      Quicksilver.Tools.Registry,

      # Add the tool agent with your chosen backend module
      {Quicksilver.Agents.ToolAgent,
       [
         backend_module: Quicksilver.Backends.LlamaCpp,
         name: Quicksilver.Agents.ToolAgent
       ]}
    ]
    
    opts = [strategy: :one_for_one, name: Quicksilver.Supervisor]
    
    # Start the supervisor
    {:ok, pid} = Supervisor.start_link(children, opts)
    
    # Register default tools after startup
    Quicksilver.Tools.register_default_tools()
    
    {:ok, pid}
  end
end
```

## Step 7: Interactive Testing Script

### Create `test_tools.exs`
```elixir
#!/usr/bin/env elixir

# Simple test script to verify everything works
# Run with: mix run test_tools.exs

# Ensure the application is started
{:ok, _} = Application.ensure_all_started(:quicksilver)

# Wait for everything to initialize
Process.sleep(1000)

IO.puts("\n🤖 Quicksilver Tool Agent Test\n")
IO.puts("Available tools:")
Quicksilver.Tools.Registry.list_tools()
|> Enum.each(fn tool ->
  IO.puts("  • #{tool["name"]}: #{tool["description"]}")
end)

IO.puts("\n" <> String.duplicate("-", 50) <> "\n")

# Test 1: Read a file
IO.puts("Test 1: Reading a file")
task1 = "Please read the contents of the README.md file"
case Quicksilver.Agents.ToolAgent.execute_task(task1) do
  {:ok, response} -> 
    IO.puts("✅ Success: #{String.slice(response, 0, 200)}...")
  {:error, error} -> 
    IO.puts("❌ Error: #{error}")
end

IO.puts("\n" <> String.duplicate("-", 50) <> "\n")

# Test 2: Search for a pattern
IO.puts("Test 2: Searching for a pattern")
task2 = "Search for files containing the word 'defmodule' in the lib directory"
case Quicksilver.Agents.ToolAgent.execute_task(task2) do
  {:ok, response} -> 
    IO.puts("✅ Success: #{String.slice(response, 0, 500)}...")
  {:error, error} -> 
    IO.puts("❌ Error: #{error}")
end

IO.puts("\n" <> String.duplicate("-", 50) <> "\n")

# Interactive mode
IO.puts("Interactive mode (type 'exit' to quit):\n")

Stream.repeatedly(fn ->
  IO.gets("Your task: ") |> String.trim()
end)
|> Stream.take_while(&(&1 != "exit"))
|> Enum.each(fn task ->
  IO.puts("\nProcessing...\n")
  
  case Quicksilver.Agents.ToolAgent.execute_task(task) do
    {:ok, response} -> 
      IO.puts("Response: #{response}\n")
    {:error, error} -> 
      IO.puts("Error: #{error}\n")
  end
end)

IO.puts("\nGoodbye! 👋")
```

## Usage Example

After implementing all the above files:

```bash
# In your Quicksilver project directory
mix compile

# Run the test script
mix run test_tools.exs
```

Or use it programmatically:

```elixir
# In IEx
iex> {:ok, response} = Quicksilver.Agents.ToolAgent.execute_task(
  "Find all functions that handle errors in the lib folder"
)

iex> {:ok, response} = Quicksilver.Agents.ToolAgent.execute_task(
  "Read the mix.exs file and tell me what dependencies we have"
)
```

## Important Notes

1. **Backend Integration**: The agent works with any backend module that implements `Quicksilver.Backends.Behaviour`. Your backend must have a `completion/2` function that takes a prompt string and options keyword list, returning `{:ok, response_text}` or `{:error, reason}`.

   Example backend implementation:
   ```elixir
   defmodule Quicksilver.Backends.LlamaCpp do
     @behaviour Quicksilver.Backends.Behaviour

     @impl true
     def completion(prompt, opts) do
       # Your implementation here
       {:ok, response_text}
     end
   end
   ```

2. **Model Requirements**: Works best with models that can follow instructions and output JSON. Models like Mistral, Llama 3, or CodeLlama work well.

3. **JSON Parsing**: The formatter is lenient and tries multiple approaches to extract tool calls from LLM responses.

4. **Safety**: Only read operations are implemented. File writes and shell commands are intentionally excluded from this minimal version.

5. **Context Window**: Be mindful of context size. The agent accumulates history, which might fill up the context window after several tool calls.

## Troubleshooting

If tool calls aren't being detected:
1. Check your model - some models need specific prompting
2. Try adding an example in the system prompt
3. Enable debug logging: `Logger.configure(level: :debug)`

If the LlamaCpp backend isn't responding:
1. Ensure your llama.cpp server is running
2. Check the model supports the context size you're sending
3. Verify the model file path and parameters

## Next Steps

Once this is working, you can:
1. Add more tools (file write, git operations)
2. Implement approval system for dangerous operations  
3. Add streaming support for long operations
4. Implement context window management
5. Add tool result caching

This minimal implementation gives you a working foundation that you can build upon. The key is that you now have the tool-calling loop working end-to-end with your LLM.