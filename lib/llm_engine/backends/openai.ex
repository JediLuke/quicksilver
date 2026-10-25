defmodule Quicksilver.LlmEngine.Backends.OpenAI do
  @moduledoc """
  OpenAI API backend: an `OpenAICompatible` preset for api.openai.com, with
  native tool calling.

  Stateless module — no GenServer needed. Each call is an independent HTTP request.

  ## Configuration

      config :quicksilver, Quicksilver.LlmEngine.Backends.OpenAI,
        api_key: System.get_env("OPENAI_API_KEY"),
        model: "gpt-4o"

  Accepts every `OpenAICompatible` key; `base_url` defaults to OpenAI's.
  """

  @behaviour Quicksilver.LlmEngine.Backend

  alias Quicksilver.LlmEngine.Backends.OpenAICompatible

  @defaults %{
    base_url: "https://api.openai.com/v1",
    api_key_env: "OPENAI_API_KEY",
    model: "gpt-4o"
  }

  @impl true
  def complete(messages, options \\ []), do: OpenAICompatible.chat(config(), messages, options)

  @impl true
  def health_check(_options \\ []), do: OpenAICompatible.check_models_endpoint(config())

  @impl true
  def native_tools?, do: true

  defp config do
    configured =
      (Application.get_env(:quicksilver, __MODULE__) || [])
      |> Map.new()
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Map.merge(@defaults, configured)
  end
end
