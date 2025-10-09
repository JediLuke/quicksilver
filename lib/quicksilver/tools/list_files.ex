defmodule Quicksilver.Tools.ListFiles do
  @moduledoc """
  Tool for listing files in a directory with optional glob patterns.
  """

  @behaviour Quicksilver.Tools.Behaviour

  @impl true
  def name, do: "list_files"

  @impl true
  def description do
    """
    List files in a directory matching an optional pattern.
    Useful for exploring the codebase structure.
    """
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "directory" => %{
          "type" => "string",
          "description" => "Directory to list (default: workspace root)"
        },
        "pattern" => %{
          "type" => "string",
          "description" => "Glob pattern like '*.ex' or '**/*.exs'"
        }
      }
    }
  end

  @impl true
  def execute(args, context) do
    workspace_root = Map.get(context, :workspace_root, File.cwd!())
    directory = Map.get(args, "directory", ".")
    pattern = Map.get(args, "pattern", "**/*")

    search_dir = resolve_path(directory, workspace_root)
    glob_pattern = Path.join(search_dir, pattern)

    files =
      Path.wildcard(glob_pattern)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, workspace_root))
      |> Enum.sort()

    result =
      if length(files) > 50 do
        "Found #{length(files)} files (showing first 50):\n" <>
        (Enum.take(files, 50) |> Enum.join("\n"))
      else
        "Found #{length(files)} files:\n" <> Enum.join(files, "\n")
      end

    {:ok, result}
  end

  defp resolve_path(path, workspace_root) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(workspace_root, path) |> Path.expand()
    end
  end
end
