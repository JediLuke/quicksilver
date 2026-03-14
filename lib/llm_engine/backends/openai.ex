defmodule Quicksilver.LlmEngine.Backends.OpenAI do
  @moduledoc """
  OpenAI API backend.

  Stateless module — no GenServer needed. Each call is an independent HTTP request.

  ## Configuration

      config :quicksilver, Quicksilver.LlmEngine.Backends.OpenAI,
        api_key: System.get_env("OPENAI_API_KEY"),
        model: "gpt-4o"
  """

  @behaviour Quicksilver.LlmEngine.Backend

  require Logger

  @default_model "gpt-4o"
  @api_url "https://api.openai.com/v1/chat/completions"

  @impl true
  def complete(messages, options \\ []) do
    config = get_config()
    api_key = Keyword.get(options, :api_key, config[:api_key])
    model = Keyword.get(options, :model, config[:model] || @default_model)

    unless api_key do
      {:error, :missing_api_key}
    else
      payload = %{
        "model" => model,
        "messages" => Enum.map(messages, &encode_message/1),
        "temperature" => Keyword.get(options, :temperature, 0.7),
        "max_tokens" => Keyword.get(options, :max_tokens, 4096)
      }

      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]

      case Req.post(@api_url, json: payload, headers: headers, receive_timeout: 120_000) do
        {:ok, %{status: 200, body: body}} ->
          extract_response(body)

        {:ok, %{status: status, body: body}} ->
          error_msg = extract_error(body)
          Logger.error("OpenAI API error (#{status}): #{error_msg}")
          {:error, "OpenAI API error (#{status}): #{error_msg}"}

        {:error, reason} ->
          Logger.error("OpenAI request failed: #{inspect(reason)}")
          {:error, "Request failed: #{inspect(reason)}"}
      end
    end
  end

  @impl true
  def health_check(_options \\ []) do
    config = get_config()

    if config[:api_key] do
      :ok
    else
      {:error, :missing_api_key}
    end
  end

  defp extract_response(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    {:ok, content}
  end

  defp extract_response(body) do
    {:error, "Unexpected response format: #{inspect(body)}"}
  end

  defp extract_error(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error(body), do: inspect(body)

  defp encode_message(%{role: role, content: content}) when is_binary(content),
    do: %{"role" => role, "content" => content}

  defp encode_message(%{role: role, content: content}) when is_list(content),
    do: %{"role" => role, "content" => Enum.map(content, &encode_content_block/1)}

  defp encode_content_block(%{type: "text", text: text}),
    do: %{"type" => "text", "text" => text}

  defp encode_content_block(%{type: "image_url", image_url: %{url: url}}),
    do: %{"type" => "image_url", "image_url" => %{"url" => url}}

  defp get_config do
    Application.get_env(:quicksilver, __MODULE__) || []
  end
end
