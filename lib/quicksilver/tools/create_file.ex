defmodule Quicksilver.Tools.CreateFile do
  @moduledoc """
  Tool for creating new files with specified content.
  """

  @behaviour Quicksilver.Tools.Behaviour

  require Logger

  @impl true
  def name, do: "create_file"

  @impl true
  def description do
    """
    Create a new file with the specified content.
    Creates parent directories if they don't exist.
    """
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path for the new file"},
        "content" => %{"type" => "string", "description" => "File contents"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def execute(%{"path" => path, "content" => content}, context) do
    workspace_root = Map.get(context, :workspace_root, File.cwd!())
    full_path = resolve_path(path, workspace_root)

    cond do
      File.exists?(full_path) ->
        {:error, "File already exists: #{path}"}

      true ->
        case request_approval_if_needed(path, content, context) do
          :approved ->
            File.mkdir_p!(Path.dirname(full_path))

            case File.write(full_path, content) do
              :ok ->
                Logger.info("Created file: #{path}")
                {:ok, "Created file: #{path} (#{byte_size(content)} bytes)"}
              {:error, reason} ->
                {:error, "Failed to create file: #{inspect(reason)}"}
            end

          :rejected -> {:error, "File creation rejected"}
          :quit_session -> {:error, "Session terminated"}
        end
    end
  end

  defp request_approval_if_needed(path, content, context) do
    policy = Map.get(context, :approval_policy, Quicksilver.Approval.Policy.default())

    if Quicksilver.Approval.Policy.should_request_approval?(policy, "create_file", %{path: path}) do
      Quicksilver.Approval.Interactive.request_approval(:file_create, %{path: path, content: content})
    else
      :approved
    end
  end

  defp resolve_path(path, workspace_root) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(workspace_root, path) |> Path.expand()
    end
  end
end
