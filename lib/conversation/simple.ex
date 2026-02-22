defmodule Quicksilver.Conversation.Simple do
  @moduledoc """
  Simple send strategy for bare conversations (no tools).

  Makes a single LLM call with the system prompt (if any) and conversation
  history, appends the exchange to history, and returns.
  """

  require Logger

  alias Quicksilver.Conversation
  alias Quicksilver.Agentic.Tools.Formatter

  @doc """
  Send a message in a bare conversation (no tools).

  Builds a prompt from the system prompt + history + new message, calls the
  LLM once, and returns the response with updated history.
  """
  @spec send(Conversation.t(), String.t()) :: {:ok, String.t(), Conversation.t()} | {:error, String.t()}
  def send(%Conversation{} = conv, message) do
    history = conv.history ++ [%{role: "user", content: message}]
    prompt = Formatter.simple_prompt(conv.system_prompt, history)
    messages = [%{role: "user", content: prompt}]

    task = Task.async(fn ->
      conv.backend_module.complete(conv.backend_pid, messages, [])
    end)

    case Task.yield(task, conv.per_iteration_timeout) || Task.shutdown(task) do
      {:ok, {:ok, response}} ->
        response = String.trim(response)
        updated_history = history ++ [%{role: "assistant", content: response}]
        {:ok, response, %{conv | history: updated_history}}

      {:ok, {:error, reason}} ->
        Logger.error("Backend error: #{reason}")
        {:error, "Backend error: #{reason}"}

      nil ->
        Logger.error("LLM call timed out after #{conv.per_iteration_timeout}ms")
        {:error, "LLM call timed out"}
    end
  end
end
