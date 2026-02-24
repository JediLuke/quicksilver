defmodule Quicksilver.Context do
  @moduledoc """
  The accumulated state for an LLM interaction.

  A Context is a data structure (not a process) that tracks message history
  and configuration. The simplest context is a bare chat: no tools, no system
  prompt. Send a message, get a response, history grows. A tool-calling context
  adds an iterative tool-execution loop before producing a final answer.

  The difference between a bare chat and a tool-calling session is just struct
  state (`tools: :none` vs `tools: :all`), not separate modules.

  Quicksilver provides ephemeral conversation threads, not agents. Real agents —
  things with goals, directives, persistence — belong in a layer above Quicksilver.
  Each such agent might own one or more Quicksilver contexts.

  ## Examples

      # Bare chat
      ctx = Quicksilver.Context.new()
      {:ok, response, ctx} = Quicksilver.Context.send(ctx, "Hello!")

      # OpenAI backend
      ctx = Quicksilver.Context.new(backend: :openai)
      {:ok, response, ctx} = Quicksilver.Context.send(ctx, "Hello!")

      # Tool-calling context
      ctx = Quicksilver.Context.new(
        tools: :all,
        workspace_root: File.cwd!()
      )
      {:ok, response, ctx} = Quicksilver.Context.send(ctx, "Read mix.exs")

      # Selective tools
      ctx = Quicksilver.Context.new(
        tools: ["read_file", "search_files", "list_files"]
      )

  """

  require Logger

  alias Quicksilver.Tools.{Registry, Formatter}

  defstruct history: [],
            system_prompt: nil,
            tools: :none,
            backend: :llama_cpp,
            backend_state: %{},
            workspace_root: nil,
            max_iterations: 50,
            per_iteration_timeout: 300_000,
            approve: nil

  @type approve_fn :: (atom(), map() -> :approved | :rejected | :quit_session) | nil

  @type t :: %__MODULE__{
          history: [map()],
          system_prompt: String.t() | nil,
          tools: :none | :all | [String.t()],
          backend: atom(),
          backend_state: map(),
          workspace_root: String.t() | nil,
          max_iterations: pos_integer(),
          per_iteration_timeout: pos_integer(),
          approve: approve_fn()
        }

  @doc """
  Create a new context.

  ## Options

  - `:system_prompt` - System prompt prepended to every LLM call (default: nil)
  - `:tools` - `:none` (bare chat), `:all`, or list of tool name strings (default: `:none`)
  - `:backend` - Backend key atom or module (default: `:llama_cpp`)
  - `:backend_state` - Initial backend state map (default: `%{}`)
  - `:workspace_root` - Base directory for file operations (default: nil)
  - `:max_iterations` - Max tool-calling iterations per send (default: 50)
  - `:per_iteration_timeout` - Timeout per LLM call in ms (default: 300_000)
  - `:approve` - Approval callback `fn(action_type, details) -> :approved | :rejected | :quit_session` (default: nil, auto-approves all)
  - `:history` - Initial message history (default: [])
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      history: Keyword.get(opts, :history, []),
      system_prompt: Keyword.get(opts, :system_prompt),
      tools: Keyword.get(opts, :tools, :none),
      backend: Keyword.get(opts, :backend, :llama_cpp),
      backend_state: Keyword.get(opts, :backend_state, %{}),
      workspace_root: Keyword.get(opts, :workspace_root),
      max_iterations: Keyword.get(opts, :max_iterations, 50),
      per_iteration_timeout: Keyword.get(opts, :per_iteration_timeout, 300_000),
      approve: Keyword.get(opts, :approve)
    }
  end

  @doc """
  Send a message and get a response.

  For bare contexts (tools: :none), makes a single LLM call.
  For tool-calling contexts, runs an iterative loop until the LLM
  produces a final text response.

  Returns `{:ok, response, updated_context}` or `{:error, reason}`.
  """
  @spec send(t(), String.t()) :: {:ok, String.t(), t()} | {:error, String.t()}
  def send(%__MODULE__{tools: :none} = ctx, message) do
    history = ctx.history ++ [%{role: "user", content: message}]
    prompt = Formatter.simple_prompt(ctx.system_prompt, history)
    messages = [%{role: "user", content: prompt}]

    task = Task.async(fn ->
      Quicksilver.LlmEngine.complete_with_state(messages, ctx.backend_state, backend: ctx.backend)
    end)

    case Task.yield(task, ctx.per_iteration_timeout) || Task.shutdown(task) do
      {:ok, {:ok, response, new_backend_state}} ->
        response = String.trim(response)
        updated_history = history ++ [%{role: "assistant", content: response}]
        {:ok, response, %{ctx | history: updated_history, backend_state: new_backend_state}}

      {:ok, {:error, reason}} ->
        Logger.error("Backend error: #{reason}")
        {:error, "Backend error: #{reason}"}

      nil ->
        Logger.error("LLM call timed out after #{ctx.per_iteration_timeout}ms")
        {:error, "LLM call timed out"}
    end
  end

  def send(%__MODULE__{} = ctx, message) do
    history = ctx.history ++ [%{role: "user", content: message}]

    tool_context = %{
      workspace_root: ctx.workspace_root || File.cwd!(),
      approve: ctx.approve
    }

    Logger.info("Sending message: #{String.slice(message, 0..100)}...")

    case iterate(ctx, history, tool_context, ctx.max_iterations, 1) do
      {:ok, response, updated_history, new_backend_state} ->
        {:ok, response, %{ctx | history: updated_history, backend_state: new_backend_state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Return the message history.
  """
  @spec history(t()) :: [map()]
  def history(%__MODULE__{history: history}), do: history

  @doc """
  Clear the message history, preserving configuration.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = ctx), do: %{ctx | history: []}

  ## Tool loop internals

  defp iterate(_ctx, _history, _tool_context, 0, _iteration) do
    error_msg = "Maximum iterations reached without final answer"
    Logger.warning(error_msg)
    {:error, error_msg}
  end

  defp iterate(ctx, history, tool_context, iterations_left, iteration) do
    Logger.debug("Iteration #{iteration}, remaining: #{iterations_left}")

    tools = get_available_tools(ctx.tools)
    prompt = build_tool_prompt(tools, history)
    messages = [%{role: "user", content: prompt}]

    task = Task.async(fn ->
      Quicksilver.LlmEngine.complete_with_state(messages, ctx.backend_state, backend: ctx.backend)
    end)

    case Task.yield(task, ctx.per_iteration_timeout) || Task.shutdown(task) do
      {:ok, {:ok, response, new_backend_state}} ->
        ctx = %{ctx | backend_state: new_backend_state}
        Logger.debug("LLM response: #{String.slice(response, 0..200)}...")

        case Formatter.parse_tool_call(response) do
          {:tool_call, tool_name, args} ->
            handle_tool_call(ctx, tool_name, args, history, tool_context, iterations_left, iteration)

          {:text_response, text} ->
            Logger.info("Completed after #{iteration} iteration(s)")
            final_history = history ++ [%{role: "assistant", content: text}]
            {:ok, text, final_history, ctx.backend_state}

          {:error, reason} ->
            Logger.error("Failed to parse LLM response: #{reason}")
            {:error, "Failed to parse response: #{reason}"}
        end

      {:ok, {:error, reason}} ->
        Logger.error("Backend error: #{reason}")
        {:error, "Backend error: #{reason}"}

      nil ->
        Logger.error("LLM call timed out after #{ctx.per_iteration_timeout}ms")
        {:error, "LLM call timed out"}
    end
  end

  defp handle_tool_call(ctx, tool_name, args, history, tool_context, iterations_left, iteration) do
    Logger.info("Tool call: #{tool_name} with args: #{inspect(args)}")

    tool_call_msg = "Using tool: #{tool_name}"
    history = history ++ [%{role: "assistant", content: tool_call_msg}]

    case Registry.execute_tool(tool_name, args, tool_context) do
      {:ok, result} ->
        Logger.debug("Tool succeeded: #{String.slice(result, 0..200)}...")
        formatted_result = Formatter.format_tool_result(tool_name, result)
        history = history ++ [%{role: "tool", content: formatted_result}]
        iterate(ctx, history, tool_context, iterations_left - 1, iteration + 1)

      {:error, reason} ->
        Logger.warning("Tool failed: #{reason}")
        formatted_error = Formatter.format_tool_result(tool_name, {:error, reason})
        history = history ++ [%{role: "tool", content: formatted_error}]
        iterate(ctx, history, tool_context, iterations_left - 1, iteration + 1)
    end
  end

  defp build_tool_prompt(tools, history) do
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
