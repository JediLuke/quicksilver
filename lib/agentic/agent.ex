defmodule Quicksilver.Agentic.Agent do
  @moduledoc """
  Stateless agent that implements an agentic loop with tool-calling capabilities.

  The agent takes a task, iteratively invokes the LLM backend, parses tool calls,
  executes tools, and returns a final response. Conversation history is managed
  by the caller (e.g., the terminal interface).
  """

  require Logger

  alias Quicksilver.Agentic.Tools.{Registry, Formatter}
  alias Quicksilver.LlmEngine.Backends.LlamaCpp

  @default_max_iterations 50
  @default_timeout 300_000  # 5 minutes per iteration

  @doc """
  Execute a task using available tools.

  The agent will use tools as needed to complete the task and return
  a final text response along with the updated conversation history.

  ## Options
  - `:backend_module` - LLM backend module (default: LlamaCpp)
  - `:backend_pid` - Backend process name/pid (default: backend module)
  - `:conversation_history` - Prior conversation messages (default: [])
  - `:max_iterations` - Maximum number of LLM calls (default: #{@default_max_iterations})
  - `:per_iteration_timeout` - Timeout per LLM call in ms (default: #{@default_timeout})
  - `:workspace_root` - Base directory for file operations (default: cwd)
  - `:allowed_tools` - List of tool names or :all (default: :all)

  ## Returns
  - `{:ok, response, updated_history}` on success
  - `{:error, reason}` on failure
  """
  @spec execute_task(String.t(), keyword()) ::
          {:ok, String.t(), list()} | {:error, String.t()}
  def execute_task(task, opts \\ []) do
    backend_module = Keyword.get(opts, :backend_module, LlamaCpp)
    backend_pid = Keyword.get(opts, :backend_pid, backend_module)
    conversation_history = Keyword.get(opts, :conversation_history, [])
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    per_iteration_timeout = Keyword.get(opts, :per_iteration_timeout, @default_timeout)
    workspace_root = Keyword.get(opts, :workspace_root, File.cwd!())
    allowed_tools = Keyword.get(opts, :allowed_tools, :all)

    context = %{workspace_root: workspace_root}

    state = %{
      backend_module: backend_module,
      backend_pid: backend_pid,
      allowed_tools: allowed_tools
    }

    initial_history = conversation_history ++ [%{role: "user", content: task}]

    Logger.info("Executing task: #{String.slice(task, 0..100)}...")

    case execute_with_tools(initial_history, context, max_iterations, state, per_iteration_timeout) do
      {{:ok, response}, history} ->
        {:ok, response, history}

      {{:error, reason}, _history} ->
        {:error, reason}
    end
  end

  ## Private Functions

  defp execute_with_tools(history, context, iterations_left, state, per_iteration_timeout, iteration \\ 1) do
    context = context |> Map.put_new(:approval_policy, Quicksilver.Agentic.Approval.Policy.default())

    if iterations_left <= 0 do
      error_msg = "Maximum iterations reached without final answer"
      Logger.warning(error_msg)
      {{:error, error_msg}, history}
    else
      Logger.debug("Iteration #{iteration}, remaining: #{iterations_left}")

      tools = get_available_tools(state)
      prompt = build_prompt(tools, history)
      messages = [%{role: "user", content: prompt}]

      task = Task.async(fn ->
        state.backend_module.complete(state.backend_pid, messages, [])
      end)

      case Task.yield(task, per_iteration_timeout) || Task.shutdown(task) do
        {:ok, {:ok, response}} ->
          Logger.debug("LLM response: #{String.slice(response, 0..200)}...")

          case Formatter.parse_tool_call(response) do
            {:tool_call, tool_name, args} ->
              handle_tool_call(tool_name, args, history, context, iterations_left, state, per_iteration_timeout, iteration)

            {:text_response, text} ->
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

    tool_call_msg = "Using tool: #{tool_name}"
    history = history ++ [%{role: "assistant", content: tool_call_msg}]

    case Registry.execute_tool(tool_name, args, context) do
      {:ok, result} ->
        Logger.debug("Tool succeeded: #{String.slice(result, 0..200)}...")

        formatted_result = Formatter.format_tool_result(tool_name, result)
        history = history ++ [%{role: "tool", content: formatted_result}]

        execute_with_tools(history, context, iterations_left - 1, state, per_iteration_timeout, iteration + 1)

      {:error, reason} ->
        Logger.warning("Tool failed: #{reason}")

        formatted_error = Formatter.format_tool_result(tool_name, {:error, reason})
        history = history ++ [%{role: "tool", content: formatted_error}]

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

  defp get_available_tools(state) do
    all_tools = Registry.list_tools()

    case state.allowed_tools do
      :all ->
        all_tools

      tool_names when is_list(tool_names) ->
        Enum.filter(all_tools, fn tool -> tool.name in tool_names end)
    end
  end
end
