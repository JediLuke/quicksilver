defmodule Quicksilver.LlmEngine do
  @moduledoc """
  Public API facade for the LLM Engine layer.

  Provides a clean interface for LLM completions and health checks,
  delegating to the configured backend.
  """

  @backends %{
    llama_cpp: Quicksilver.LlmEngine.Backends.LlamaCpp,
    openai: Quicksilver.LlmEngine.Backends.OpenAI,
    anthropic: Quicksilver.LlmEngine.Backends.Anthropic,
    claude_cli: Quicksilver.LlmEngine.Backends.ClaudeCli
  }

  @doc """
  Send a completion request to the LLM backend.

  ## Options
  - `:backend` - Backend key atom or module (default: :llama_cpp)
  - All other options are passed through to the backend.
  """
  @spec complete([map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts \\ []) do
    {backend_key, opts} = Keyword.pop(opts, :backend, :llama_cpp)
    resolve_backend(backend_key).complete(messages, opts)
  end

  @doc """
  Send a completion request with state tracking (for stateful backends).

  Returns `{:ok, response, updated_state}` or `{:error, reason}`.
  Falls back to `complete/2` and returns state unchanged if the backend
  doesn't implement `complete_with_state/3`.
  """
  @spec complete_with_state([map()], map(), keyword()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def complete_with_state(messages, state, opts \\ []) do
    {backend_key, opts} = Keyword.pop(opts, :backend, :llama_cpp)
    backend = resolve_backend(backend_key)

    if function_exported?(backend, :complete_with_state, 3) do
      backend.complete_with_state(messages, state, opts)
    else
      case backend.complete(messages, opts) do
        {:ok, response} -> {:ok, response, state}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Check the health of the LLM backend.
  """
  @spec health_check(keyword()) :: :ok | {:error, term()}
  def health_check(opts \\ []) do
    {backend_key, opts} = Keyword.pop(opts, :backend, :llama_cpp)
    resolve_backend(backend_key).health_check(opts)
  end

  @doc """
  Resolve a backend key to its module.

  If the key is a known atom (:llama_cpp, :openai, etc.), returns the
  corresponding module. Otherwise treats the key as a module directly
  (useful for testing with mock backends).
  """
  @spec resolve_backend(atom()) :: module()
  def resolve_backend(key) when is_atom(key) do
    Map.get(@backends, key, key)
  end
end
