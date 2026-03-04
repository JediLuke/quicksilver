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
    List files and directories. Without a pattern, lists top-level entries
    in the given directory (including subdirectory names ending with /).
    With a glob pattern like '**/*.ex', recursively finds matching files.
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
          "description" => "Glob pattern like '*.ex' or '**/*.exs'. If omitted, lists top-level entries."
        }
      }
    }
  end

  @impl true
  def execute(args, context) do
    workspace_root = Map.get(context, :workspace_root, File.cwd!())
    directory = Map.get(args, "directory", ".")
    pattern = Map.get(args, "pattern")

    search_dir = resolve_path(directory, workspace_root)

    if pattern do
      list_with_pattern(search_dir, pattern, workspace_root)
    else
      list_top_level(search_dir, workspace_root)
    end
  end

  defp list_top_level(search_dir, workspace_root) do
    case File.ls(search_dir) do
      {:ok, entries} ->
        entries =
          entries
          |> Enum.sort()
          |> Enum.map(fn entry ->
            full_path = Path.join(search_dir, entry)
            if File.dir?(full_path), do: entry <> "/", else: entry
          end)

        result =
          if length(entries) > 100 do
            "Found #{length(entries)} entries (showing first 100):\n" <>
              (Enum.take(entries, 100) |> Enum.join("\n"))
          else
            "Found #{length(entries)} entries:\n" <> Enum.join(entries, "\n")
          end

        {:ok, result}

      {:error, reason} ->
        {:error, "Cannot list directory #{Path.relative_to(search_dir, workspace_root)}: #{reason}"}
    end
  end

  defp list_with_pattern(search_dir, pattern, workspace_root) do
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
