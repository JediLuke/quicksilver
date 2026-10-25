defmodule Quicksilver.LlmEngine.Backends.Anthropic do
  @moduledoc """
  Anthropic API backend.

  Stateless module — no GenServer needed. Each call is an independent HTTP request.

  Anthropic's API separates the system message from the messages list, so this
  backend extracts any system-role message and passes it as the `system` parameter.

  ## Configuration

      config :quicksilver, Quicksilver.LlmEngine.Backends.Anthropic,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        model: "claude-sonnet-4-6"
  """

  @behaviour Quicksilver.LlmEngine.Backend

  require Logger

  @default_model "claude-sonnet-4-6"
  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"

  @impl true
  def complete(messages, options \\ []) do
    config = get_config()
    api_key = Keyword.get(options, :api_key, config[:api_key])
    model = Keyword.get(options, :model, config[:model] || @default_model)

    unless api_key do
      {:error, :missing_api_key}
    else
      {system_msg, chat_messages} = extract_system_message(messages)

      payload =
        %{
          model: model,
          messages: chat_messages,
          max_tokens: Keyword.get(options, :max_tokens, 4096),
          temperature: Keyword.get(options, :temperature, 0.7)
        }
        |> maybe_add_system(system_msg)

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", @api_version},
        {"content-type", "application/json"}
      ]

      case Req.post(@api_url, json: payload, headers: headers, receive_timeout: 120_000) do
        {:ok, %{status: 200, body: body}} ->
          extract_response(body)

        {:ok, %{status: status, body: body}} ->
          error_msg = extract_error(body)
          Logger.error("Anthropic API error (#{status}): #{error_msg}")
          {:error, "Anthropic API error (#{status}): #{error_msg}"}

        {:error, reason} ->
          Logger.error("Anthropic request failed: #{inspect(reason)}")
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

  defp extract_system_message(messages) do
    {system_msgs, other_msgs} = Enum.split_with(messages, fn msg ->
      msg[:role] == "system" || msg["role"] == "system"
    end)

    system_text = case system_msgs do
      [] -> nil
      msgs ->
        msgs
        |> Enum.map(fn msg -> msg[:content] || msg["content"] end)
        |> Enum.join("\n\n")
    end

    {system_text, other_msgs}
  end

  defp maybe_add_system(payload, nil), do: payload
  defp maybe_add_system(payload, system), do: Map.put(payload, :system, system)

  defp extract_response(%{"content" => [%{"text" => text} | _]}) do
    {:ok, text}
  end

  defp extract_response(body) do
    {:error, "Unexpected response format: #{inspect(body)}"}
  end

  defp extract_error(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error(body), do: inspect(body)

  defp get_config do
    Application.get_env(:quicksilver, __MODULE__) || []
  end
end
