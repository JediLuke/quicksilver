defmodule Quicksilver.LlmEngine do
  @moduledoc """
  Public API facade for the LLM Engine layer.

  Provides a clean interface for LLM completions and health checks,
  delegating to the configured backend.
  """

  alias Quicksilver.LlmEngine.Backends.LlamaCpp

  @doc """
  Send a completion request to the LLM backend.

  ## Options
  - `:backend` - Backend module (default: LlamaCpp)
  - `:pid` - Backend process pid/name (default: backend module name)
  - All other options are passed through to the backend.
  """
  @spec complete([map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts \\ []) do
    {backend, opts} = Keyword.pop(opts, :backend, LlamaCpp)
    {pid, opts} = Keyword.pop(opts, :pid, backend)
    backend.complete(pid, messages, opts)
  end

  @doc """
  Check the health of the LLM backend.
  """
  @spec health_check(keyword()) :: :ok | {:error, term()}
  def health_check(opts \\ []) do
    backend = Keyword.get(opts, :backend, LlamaCpp)
    pid = Keyword.get(opts, :pid, backend)
    backend.health_check(pid)
  end
end
