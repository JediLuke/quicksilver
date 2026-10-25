defmodule Quicksilver.LlmEngine do
  @moduledoc """
  Public API facade for the LLM Engine layer.

  Provides a clean interface for LLM completions and health checks,
  delegating to the configured backend.
  """

  @backends %{
    llama_cpp: Quicksilver.LlmEngine.Backends.LlamaCpp,
    openai_compatible: Quicksilver.LlmEngine.Backends.OpenAICompatible,
    openai: Quicksilver.LlmEngine.Backends.OpenAI,
    anthropic: Quicksilver.LlmEngine.Backends.Anthropic,
    claude_cli: Quicksilver.LlmEngine.Backends.ClaudeCli
  }

  @backend_labels %{
    llama_cpp: "Llama.cpp (local)",
    claude_cli: "Claude CLI",
    openai_compatible: "OpenAI-compatible API",
    openai: "OpenAI",
    anthropic: "Anthropic API"
  }

  def available_backends, do: Map.keys(@backends)
  def backend_labels, do: @backend_labels

  @doc """
  The backend used when none is given: the `:backend` config key, which
  `config/config.exs` reads from `QUICKSILVER_BACKEND` (default `:llama_cpp`).
  Accepts an atom or string naming one of `available_backends/0`.
  """
  @spec default_backend() :: atom()
  def default_backend do
    case Application.get_env(:quicksilver, :backend, :llama_cpp) do
      key when is_atom(key) ->
        key

      name when is_binary(name) ->
        Enum.find(available_backends(), &(Atom.to_string(&1) == name)) ||
          raise ArgumentError,
                "unknown backend #{inspect(name)}, expected one of: " <>
                  Enum.map_join(available_backends(), ", ", &Atom.to_string/1)
    end
  end

  @doc """
  True when the backend supports native (structured) tool calling.
  """
  @spec native_tools?(atom()) :: boolean()
  def native_tools?(backend_key) do
    backend = resolve_backend(backend_key)
    Code.ensure_loaded?(backend) and function_exported?(backend, :native_tools?, 0) and backend.native_tools?()
  end

  @doc """
  Send a completion request to the LLM backend.

  ## Options
  - `:backend` - Backend key atom or module (default: `default_backend/0`)
  - All other options are passed through to the backend.
  """
  @spec complete([map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts \\ []) do
    {backend_key, opts} = Keyword.pop_lazy(opts, :backend, &default_backend/0)
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
    {backend_key, opts} = Keyword.pop_lazy(opts, :backend, &default_backend/0)
    backend = resolve_backend(backend_key)

    # ensure_loaded: function_exported? is false for modules not loaded yet
    if Code.ensure_loaded?(backend) and function_exported?(backend, :complete_with_state, 3) do
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
    {backend_key, opts} = Keyword.pop_lazy(opts, :backend, &default_backend/0)
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
