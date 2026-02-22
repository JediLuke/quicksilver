defmodule Quicksilver.Conversation.ToolCalling do
  @moduledoc """
  Tool-calling send strategy for conversations with tools.

  Implements an iterative loop: prompt the LLM, parse for tool calls,
  execute tools, accumulate history, and repeat until the LLM produces
  a final text response (no tool call).
  """

  require Logger

  alias Quicksilver.Conversation
  alias Quicksilver.Agentic.Tools.{Registry, Formatter}

  @doc """
  Send a message in a tool-calling conversation.

  Runs an iterative loop of LLM calls and tool executions until the LLM
  produces a text response or the max iteration limit is reached.
  """
  @spec send(Conversation.t(), String.t()) :: {:ok, String.t(), Conversation.t()} | {:error, String.t()}
  def send(%Conversation{} = conv, message) do
    history = conv.history ++ [%{role: "user", content: message}]

    context = %{
      workspace_root: conv.workspace_root || File.cwd!(),
      approval_policy: conv.approval_policy || Quicksilver.Agentic.Approval.Policy.default()
    }

    Logger.info("Sending message: #{String.slice(message, 0..100)}...")

    case iterate(conv, history, context, conv.max_iterations, 1) do
      {:ok, response, updated_history} ->
        {:ok, response, %{conv | history: updated_history}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Private

  defp iterate(_conv, _history, _context, 0, _iteration) do
    error_msg = "Maximum iterations reached without final answer"
    Logger.warning(error_msg)
    {:error, error_msg}
  end

  defp iterate(conv, history, context, iterations_left, iteration) do
    Logger.debug("Iteration #{iteration}, remaining: #{iterations_left}")

    tools = get_available_tools(conv.tools)
    prompt = build_prompt(tools, history)
    messages = [%{role: "user", content: prompt}]

    task = Task.async(fn ->
      conv.backend_module.complete(conv.backend_pid, messages, [])
    end)

    case Task.yield(task, conv.per_iteration_timeout) || Task.shutdown(task) do
      {:ok, {:ok, response}} ->
        Logger.debug("LLM response: #{String.slice(response, 0..200)}...")

        case Formatter.parse_tool_call(response) do
          {:tool_call, tool_name, args} ->
            handle_tool_call(conv, tool_name, args, history, context, iterations_left, iteration)

          {:text_response, text} ->
            Logger.info("Completed after #{iteration} iteration(s)")
            final_history = history ++ [%{role: "assistant", content: text}]
            {:ok, text, final_history}

          {:error, reason} ->
            Logger.error("Failed to parse LLM response: #{reason}")
            {:error, "Failed to parse response: #{reason}"}
        end

      {:ok, {:error, reason}} ->
        Logger.error("Backend error: #{reason}")
        {:error, "Backend error: #{reason}"}

      nil ->
        Logger.error("LLM call timed out after #{conv.per_iteration_timeout}ms")
        {:error, "LLM call timed out"}
    end
  end

  defp handle_tool_call(conv, tool_name, args, history, context, iterations_left, iteration) do
    Logger.info("Tool call: #{tool_name} with args: #{inspect(args)}")

    tool_call_msg = "Using tool: #{tool_name}"
    history = history ++ [%{role: "assistant", content: tool_call_msg}]

    case Registry.execute_tool(tool_name, args, context) do
      {:ok, result} ->
        Logger.debug("Tool succeeded: #{String.slice(result, 0..200)}...")
        formatted_result = Formatter.format_tool_result(tool_name, result)
        history = history ++ [%{role: "tool", content: formatted_result}]
        iterate(conv, history, context, iterations_left - 1, iteration + 1)

      {:error, reason} ->
        Logger.warning("Tool failed: #{reason}")
        formatted_error = Formatter.format_tool_result(tool_name, {:error, reason})
        history = history ++ [%{role: "tool", content: formatted_error}]
        iterate(conv, history, context, iterations_left - 1, iteration + 1)
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

  defp get_available_tools(tools_config) do
    all_tools = Registry.list_tools()

    case tools_config do
      :all ->
        all_tools

      tool_names when is_list(tool_names) ->
        Enum.filter(all_tools, fn tool -> tool.name in tool_names end)
    end
  end
end
