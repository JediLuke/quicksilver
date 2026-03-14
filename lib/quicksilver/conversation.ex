defmodule Quicksilver.Conversation do
  @moduledoc """
  The accumulated state for an LLM interaction.

  A Conversation is a data structure (not a process) that tracks message history
  and configuration. The simplest conversation is a bare chat: no tools, no system
  prompt. Send a message, get a response, history grows. A tool-calling conversation
  adds an iterative tool-execution loop before producing a final answer.

  The difference between a bare chat and a tool-calling session is just struct
  state (`tools: :none` vs `tools: :all`), not separate modules.

  Quicksilver provides ephemeral conversation threads, not agents. Real agents —
  things with goals, directives, persistence — belong in a layer above Quicksilver.
  Each such agent might own one or more Quicksilver conversations.

  ## Examples

      # Bare chat
      ctx = Quicksilver.Conversation.new()
      {:ok, response, ctx} = Quicksilver.Conversation.send(ctx, "Hello!")

      # OpenAI backend
      ctx = Quicksilver.Conversation.new(backend: :openai)
      {:ok, response, ctx} = Quicksilver.Conversation.send(ctx, "Hello!")

      # Tool-calling conversation
      ctx = Quicksilver.Conversation.new(
        tools: :all,
        workspace_root: File.cwd!()
      )
      {:ok, response, ctx} = Quicksilver.Conversation.send(ctx, "Read mix.exs")

      # Selective tools
      ctx = Quicksilver.Conversation.new(
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
            approve: nil,
            stream_callback: nil,
            pending_images: []

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
          approve: approve_fn(),
          stream_callback: (map() -> any()) | nil,
          pending_images: [map()]
        }

  @doc """
  Create a new conversation.

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
      approve: Keyword.get(opts, :approve),
      stream_callback: Keyword.get(opts, :stream_callback)
    }
  end

  @doc """
  Send a message and get a response.

  For bare conversations (tools: :none), makes a single LLM call.
  For tool-calling conversations, runs an iterative loop until the LLM
  produces a final text response.

  Returns `{:ok, response, updated_conversation}` or `{:error, reason}`.
  """
  @spec send(t(), String.t()) :: {:ok, String.t(), t()} | {:error, String.t()}
  def send(%__MODULE__{tools: :none} = ctx, message) do
    history = ctx.history ++ [%{role: "user", content: message}]
    prompt = Formatter.simple_prompt(ctx.system_prompt, history)
    messages = [%{role: "user", content: prompt}]

    llm_opts = [backend: ctx.backend]
    llm_opts = if ctx.stream_callback,
      do: Keyword.put(llm_opts, :stream_callback, ctx.stream_callback),
      else: llm_opts

    task = Task.async(fn ->
      Quicksilver.LlmEngine.complete_with_state(messages, ctx.backend_state, llm_opts)
    end)

    case Task.yield(task, ctx.per_iteration_timeout) || Task.shutdown(task) do
      {:ok, {:ok, response, new_backend_state}} ->
        response = String.trim(response)
        updated_history = history ++ [%{role: "assistant", content: response}]
        {:ok, response, %{ctx | history: updated_history, backend_state: new_backend_state}}

      {:ok, {:error, reason}} ->
        Logger.error("[#{ctx.backend}] Backend error: #{inspect(reason)}")
        {:error, "Backend error: #{inspect(reason)}"}

      nil ->
        Logger.error("[#{ctx.backend}] LLM call timed out after #{ctx.per_iteration_timeout}ms")
        {:error, "LLM call timed out"}
    end
  end

  def send(%__MODULE__{} = ctx, message) do
    history = ctx.history ++ [%{role: "user", content: message}]

    tool_context = %{
      workspace_root: ctx.workspace_root || File.cwd!(),
      approve: ctx.approve
    }

    Logger.info("[#{ctx.backend}] Sending message: #{String.slice(message, 0..100)}...")

    case iterate(ctx, history, tool_context, ctx.max_iterations, 1, []) do
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

  defp iterate(_ctx, _history, _tool_context, 0, _iteration, _recent_calls) do
    error_msg = "Maximum iterations reached without final answer"
    Logger.warning(error_msg)
    {:error, error_msg}
  end

  defp iterate(ctx, history, tool_context, iterations_left, iteration, recent_calls) do
    Logger.debug("[#{ctx.backend}] Iteration #{iteration}, remaining: #{iterations_left}")

    tools = get_available_tools(ctx.tools)
    prompt = build_tool_prompt(tools, history)
    {messages, ctx} = build_messages_with_images(prompt, ctx)

    llm_opts = [backend: ctx.backend]
    llm_opts = if ctx.stream_callback,
      do: Keyword.put(llm_opts, :stream_callback, ctx.stream_callback),
      else: llm_opts

    task = Task.async(fn ->
      Quicksilver.LlmEngine.complete_with_state(messages, ctx.backend_state, llm_opts)
    end)

    case Task.yield(task, ctx.per_iteration_timeout) || Task.shutdown(task) do
      {:ok, {:ok, response, new_backend_state}} ->
        ctx = %{ctx | backend_state: new_backend_state}
        Logger.debug("[#{ctx.backend}] Response: #{String.slice(response, 0..200)}...")

        case Formatter.parse_tool_call(response) do
          {:tool_call, tool_name, args} ->
            handle_tool_call(ctx, tool_name, args, history, tool_context, iterations_left, iteration, recent_calls)

          {:text_response, text} ->
            Logger.info("[#{ctx.backend}] Completed after #{iteration} iteration(s)")
            final_history = history ++ [%{role: "assistant", content: text}]
            {:ok, text, final_history, ctx.backend_state}

          {:error, reason} ->
            Logger.error("Failed to parse LLM response: #{reason}")
            {:error, "Failed to parse response: #{reason}"}
        end

      {:ok, {:error, reason}} ->
        Logger.error("[#{ctx.backend}] Backend error: #{inspect(reason)}")
        {:error, "Backend error: #{inspect(reason)}"}

      nil ->
        Logger.error("[#{ctx.backend}] LLM call timed out after #{ctx.per_iteration_timeout}ms")
        {:error, "LLM call timed out"}
    end
  end

  @max_duplicate_calls 2

  defp handle_tool_call(ctx, tool_name, args, history, tool_context, iterations_left, iteration, recent_calls) do
    Logger.info("Tool call: #{tool_name} with args: #{inspect(args)}")

    call_signature = {tool_name, args}
    duplicate_count = Enum.count(recent_calls, &(&1 == call_signature))

    if duplicate_count >= @max_duplicate_calls do
      Logger.warning("Loop detected: #{tool_name} called #{duplicate_count + 1} times with same args, nudging model")

      nudge = "SYSTEM: You have already called #{tool_name} with these exact arguments #{duplicate_count + 1} times and gotten the same result. Try a different approach or provide your best answer with the information you have."
      history = history ++ [%{role: "system", content: nudge}]
      iterate(ctx, history, tool_context, iterations_left - 1, iteration + 1, [])
    else
      tool_call_msg = "Using tool: #{tool_name}"
      history = history ++ [%{role: "assistant", content: tool_call_msg}]
      recent_calls = [call_signature | recent_calls] |> Enum.take(10)

      case Registry.execute_tool(tool_name, args, tool_context) do
        {:ok, {:image, mime, base64, path}} ->
          Logger.debug("Tool returned image: #{Path.basename(path)}")
          image_block = %{type: "image_url", image_url: %{url: "data:#{mime};base64,#{base64}"}}
          ctx = %{ctx | pending_images: ctx.pending_images ++ [image_block]}
          placeholder = "Tool '#{tool_name}' returned:\n[Image loaded: #{Path.basename(path)}]"
          history = history ++ [%{role: "tool", content: placeholder}]
          iterate(ctx, history, tool_context, iterations_left - 1, iteration + 1, recent_calls)

        {:ok, result} ->
          Logger.debug("Tool succeeded: #{String.slice(result, 0..200)}...")
          formatted_result = Formatter.format_tool_result(tool_name, result)
          history = history ++ [%{role: "tool", content: formatted_result}]
          iterate(ctx, history, tool_context, iterations_left - 1, iteration + 1, recent_calls)

        {:error, reason} ->
          Logger.warning("Tool failed: #{reason}")
          formatted_error = Formatter.format_tool_result(tool_name, {:error, reason})
          history = history ++ [%{role: "tool", content: formatted_error}]
          iterate(ctx, history, tool_context, iterations_left - 1, iteration + 1, recent_calls)
      end
    end
  end

  defp build_messages_with_images(prompt, %{pending_images: []} = ctx),
    do: {[%{role: "user", content: prompt}], ctx}

  defp build_messages_with_images(prompt, %{pending_images: images} = ctx) do
    content = [%{type: "text", text: prompt} | images]
    {[%{role: "user", content: content}], %{ctx | pending_images: []}}
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
