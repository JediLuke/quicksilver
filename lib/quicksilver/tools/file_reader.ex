defmodule Quicksilver.Tools.FileReader do
  @moduledoc """
  Tool for reading file contents from the workspace.

  This is a safe, read-only tool that allows the agent to access file contents.
  Files are truncated if they exceed a reasonable size to avoid context overflow.
  """

  @behaviour Quicksilver.Tools.Behaviour

  require Logger

  @max_file_size 100_000 # 100KB - reasonable limit for context
  @truncation_message "\n\n[File truncated - content exceeds #{@max_file_size} bytes]"

  @impl true
  def name, do: "read_file"

  @impl true
  def description do
    """
    Read the contents of a file from the workspace.
    Provide the file path relative to the workspace root or as an absolute path.
    """
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path to the file to read (relative or absolute)"
        }
      },
      "required" => ["path"]
    }
  end

  @impl true
  def execute(%{"path" => path}, context) do
    workspace_root = Map.get(context, :workspace_root, File.cwd!())
    full_path = resolve_path(path, workspace_root)

    Logger.debug("Reading file: #{full_path}")

    case File.read(full_path) do
      {:ok, content} ->
        # Truncate if too large
        content = maybe_truncate(content)
        {:ok, content}

      {:error, :enoent} ->
        {:error, "File not found: #{path}"}

      {:error, :eacces} ->
        {:error, "Permission denied: #{path}"}

      {:error, :eisdir} ->
        {:error, "Path is a directory, not a file: #{path}"}

      {:error, reason} ->
        {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  def execute(_args, _context) do
    {:error, "Missing required parameter: path"}
  end

  ## Private Functions

  defp resolve_path(path, workspace_root) do
    # If absolute path, use as-is; otherwise resolve relative to workspace
    if Path.type(path) == :absolute do
      path
    else
      Path.join(workspace_root, path)
      |> Path.expand()
    end
  end

  defp maybe_truncate(content) when byte_size(content) > @max_file_size do
    content
    |> binary_part(0, @max_file_size)
    |> Kernel.<>(@truncation_message)
  end

  defp maybe_truncate(content), do: content
end
