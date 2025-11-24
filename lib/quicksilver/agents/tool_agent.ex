defmodule Quicksilver.Agents.ToolAgent do
  @moduledoc """
  GenServer that implements an agentic loop with tool-calling capabilities.

  The agent maintains conversation history, invokes the LLM backend,
  parses tool calls, executes tools via the registry, and iterates
  until a final answer is produced or max iterations is reached.
  """

  use GenServer
  require Logger

  alias Quicksilver.Tools.{Registry, Formatter}

  @default_max_iterations 50
  @default_timeout 300_000  # 5 minutes for complex multi-tool tasks

  ## Client API

  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Execute a task using available tools.

  The agent will use tools as needed to complete the task and return
  a final text response.

  Options:
  - :max_iterations - Maximum number of LLM calls (default: #{@default_max_iterations})
  - :per_iteration_timeout - Timeout per LLM call in milliseconds (default: #{@default_timeout})
  - :workspace_root - Base directory for file operations
  """
  @spec execute_task(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute_task(server \\ __MODULE__, task, opts \\ []) do
    # This overall timeout kicks in even if we're still haven't hit max iterations yet
    GenServer.call(server, {:execute_task, task, opts}, :timer.minutes(10))
  end

  @doc """
  Get the current conversation history.
  """
  def get_history(server \\ __MODULE__) do
    GenServer.call(server, :get_history)
  end

  @doc """
  Clear the conversation history.
  """
  def clear_history(server \\ __MODULE__) do
    GenServer.call(server, :clear_history)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    backend_module = Keyword.fetch!(opts, :backend_module)
    backend_pid = Keyword.get(opts, :backend_pid, LlamaCpp)

    # Verify backend implements the Backend behaviour
    unless function_exported?(backend_module, :complete, 3) do
      raise ArgumentError,
            "Backend module #{inspect(backend_module)} must implement Quicksilver.Backends.Backend behaviour"
    end

    state = %{
      backend_module: backend_module,
      backend_pid: backend_pid,
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      workspace_root: Keyword.get(opts, :workspace_root, File.cwd!()),
      conversation_history: []
    }

    Logger.info("ToolAgent started with backend: #{inspect(backend_module)}")
    {:ok, state}
  end

  @impl true
  def handle_call({:execute_task, task, opts}, _from, state) do
    max_iterations = Keyword.get(opts, :max_iterations, state.max_iterations)
    workspace_root = Keyword.get(opts, :workspace_root, state.workspace_root)
    per_iteration_timeout = Keyword.get(opts, :per_iteration_timeout, @default_timeout)
    conversation_history = Keyword.get(opts, :conversation_history, [])

    context = %{workspace_root: workspace_root}

    # Build initial history from conversation context + new task
    initial_history = conversation_history ++ [%{role: "user", content: task}]

    Logger.info("Executing task: #{String.slice(task, 0..100)}...")

    result = execute_with_tools(initial_history, context, max_iterations, state, per_iteration_timeout)

    # Update conversation history in state
    new_state = %{state | conversation_history: elem(result, 1)}

    case result do
      {{:ok, response}, _history} ->
        {:reply, {:ok, response}, new_state}

      {{:error, reason}, _history} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.conversation_history, state}
  end

  @impl true
  def handle_call(:clear_history, _from, state) do
    {:reply, :ok, %{state | conversation_history: []}}
  end

  ## Private Functions

  defp execute_with_tools(history, context, iterations_left, state, per_iteration_timeout, iteration \\ 1) do
    # Add approval policy to context
    context = context |> Map.put_new(:approval_policy, Quicksilver.Approval.Policy.default())

    if iterations_left <= 0 do
      error_msg = "Maximum iterations reached without final answer"
      Logger.warning(error_msg)
      {{:error, error_msg}, history}
    else
      Logger.debug("Iteration #{iteration}, remaining: #{iterations_left}")

      # Get available tools
      tools = Registry.list_tools()

      # Build prompt
      prompt = build_prompt(tools, history)

      # Call LLM (convert string prompt to message format)
      messages = [%{role: "user", content: prompt}]

      # Spawn a task with timeout for this single iteration
      task = Task.async(fn ->
        state.backend_module.complete(state.backend_pid, messages, [])
      end)

      case Task.yield(task, per_iteration_timeout) || Task.shutdown(task) do
        {:ok, {:ok, response}} ->
          Logger.debug("LLM response: #{String.slice(response, 0..200)}...")

          # Parse response
          case Formatter.parse_tool_call(response) do
            {:tool_call, tool_name, args} ->
              handle_tool_call(tool_name, args, history, context, iterations_left, state, per_iteration_timeout, iteration)

            {:text_response, text} ->
              # Final answer
              Logger.info("Task completed after #{iteration} iteration(s)")
              final_history = history ++ [%{role: "assistant", content: text}]
              {{:ok, text}, final_history}

            {:error, reason} ->
              Logger.error("Failed to parse LLM response: #{reason}")
              {{:error, "Failed to parse response: #{reason}"}, history}
          end

        {:ok, {:error, reason}} ->
          Logger.error("Backend error: #{reason}")
          {{:error, "Backend error: #{reason}"}, history}

        nil ->
          Logger.error("LLM call timed out after #{per_iteration_timeout}ms")
          {{:error, "LLM call timed out"}, history}
      end
    end
  end

  defp handle_tool_call(tool_name, args, history, context, iterations_left, state, per_iteration_timeout, iteration) do
    Logger.info("Tool call: #{tool_name} with args: #{inspect(args)}")

    # Add assistant's tool call to history
    tool_call_msg = "Using tool: #{tool_name}"
    history = history ++ [%{role: "assistant", content: tool_call_msg}]

    # Execute tool
    case Registry.execute_tool(tool_name, args, context) do
      {:ok, result} ->
        Logger.debug("Tool succeeded: #{String.slice(result, 0..200)}...")

        # Add tool result to history
        formatted_result = Formatter.format_tool_result(tool_name, result)
        history = history ++ [%{role: "tool", content: formatted_result}]

        # Continue loop
        execute_with_tools(history, context, iterations_left - 1, state, per_iteration_timeout, iteration + 1)

      {:error, reason} ->
        Logger.warning("Tool failed: #{reason}")

        # Add tool error to history and let LLM decide what to do
        formatted_error = Formatter.format_tool_result(tool_name, {:error, reason})
        history = history ++ [%{role: "tool", content: formatted_error}]

        # Continue loop - LLM might try different approach
        execute_with_tools(history, context, iterations_left - 1, state, per_iteration_timeout, iteration + 1)
    end
  end

  defp build_prompt(tools, history) do
    system_prompt = Formatter.system_prompt_with_tools(tools)
    conversation = Formatter.format_conversation_history(history)

    """
    #{system_prompt}

    #{conversation}

    Assistant:
    """
  end

end
