defmodule Quicksilver.Tools.EditFile do
  @moduledoc """
  Tool for editing existing files by replacing exact string matches.
  """

  @behaviour Quicksilver.Tools.Behaviour

  require Logger

  @impl true
  def name, do: "edit_file"

  @impl true
  def description do
    """
    Edit an existing file by specifying the old content to find and the new content to replace it with.
    This is the safest way to edit files - always provide enough context in old_string to uniquely identify the section.
    """
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path to the file to edit"
        },
        "old_string" => %{
          "type" => "string",
          "description" => "Exact string to find and replace (must be unique in file)"
        },
        "new_string" => %{
          "type" => "string",
          "description" => "New string to replace the old_string with"
        }
      },
      "required" => ["path", "old_string", "new_string"]
    }
  end

  @impl true
  def execute(%{"path" => path, "old_string" => old, "new_string" => new}, context) do
    workspace_root = Map.get(context, :workspace_root, File.cwd!())
    full_path = resolve_path(path, workspace_root)

    with {:ok, original} <- File.read(full_path),
         :ok <- validate_edit(original, old, new),
         edited <- String.replace(original, old, new, global: false),
         diff <- generate_diff(original, edited, path),
         :approved <- request_approval_if_needed(path, diff, context) do

      # Create backup
      backup_path = create_backup(full_path)

      case File.write(full_path, edited) do
        :ok ->
          Logger.info("Edited file: #{path}")
          {:ok, "File edited successfully:\n#{diff}\n\nBackup created: #{Path.basename(backup_path)}"}

        {:error, reason} ->
          {:error, "Failed to write file: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
      :rejected -> {:error, "Edit rejected by user"}
      :quit_session -> {:error, "Session terminated by user"}
    end
  end

  defp validate_edit(content, old, _new) do
    case {String.contains?(content, old), count_occurrences(content, old)} do
      {false, _} ->
        {:error, "old_string not found in file"}
      {true, count} when count > 1 ->
        {:error, "old_string appears #{count} times - must be unique. Provide more context to make it unique."}
      {true, 1} ->
        :ok
    end
  end

  defp count_occurrences(string, substring) do
    string
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
  end

  defp generate_diff(original, edited, filename) do
    # Simple unified diff
    original_lines = String.split(original, "\n")
    edited_lines = String.split(edited, "\n")

    # Find changed sections
    diff_lines =
      Enum.zip(original_lines, edited_lines)
      |> Enum.with_index(1)
      |> Enum.filter(fn {{o, e}, _} -> o != e end)
      |> Enum.map(fn {{o, e}, line_num} ->
        """
        @@ Line #{line_num} @@
        -#{o}
        +#{e}
        """
      end)
      |> Enum.join("\n")

    if diff_lines == "" do
      "No changes"
    else
      "--- #{filename}\n+++ #{filename}\n#{diff_lines}"
    end
  end

  defp request_approval_if_needed(path, diff, context) do
    policy = Map.get(context, :approval_policy, Quicksilver.Approval.Policy.default())

    if Quicksilver.Approval.Policy.should_request_approval?(policy, "edit_file", %{path: path}) do
      Quicksilver.Approval.Interactive.request_approval(:file_edit, %{path: path, diff: diff})
    else
      :approved
    end
  end

  defp create_backup(path) do
    backup_path = path <> ".backup." <> (:os.system_time(:millisecond) |> to_string())
    File.copy!(path, backup_path)
    backup_path
  end

  defp resolve_path(path, workspace_root) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(workspace_root, path) |> Path.expand()
    end
  end
end
