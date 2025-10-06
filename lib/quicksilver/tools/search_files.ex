defmodule Quicksilver.Tools.SearchFiles do
  @moduledoc """
  Tool for searching file contents in the workspace.

  Uses ripgrep if available, falls back to grep/find, and finally to pure Elixir.
  Results are limited to avoid overwhelming the context window.
  """

  @behaviour Quicksilver.Tools.Behaviour

  require Logger

  @max_results 20
  @max_line_length 500

  @impl true
  def name, do: "search_files"

  @impl true
  def description do
    """
    Search for text patterns in files within the workspace.
    Returns matching lines with file paths and line numbers.
    """
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Text pattern to search for"
        },
        "directory" => %{
          "type" => "string",
          "description" => "Directory to search in (relative to workspace root, defaults to entire workspace)"
        },
        "file_pattern" => %{
          "type" => "string",
          "description" => "File glob pattern to filter files (e.g., '*.ex', '*.md')"
        }
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, context) do
    workspace_root = Map.get(context, :workspace_root, File.cwd!())
    directory = Map.get(args, "directory", ".")
    file_pattern = Map.get(args, "file_pattern")

    search_dir = resolve_directory(directory, workspace_root)

    Logger.debug("Searching in #{search_dir} for pattern: #{pattern}")

    case perform_search(pattern, search_dir, file_pattern) do
      {:ok, results} ->
        format_results(results, workspace_root)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_args, _context) do
    {:error, "Missing required parameter: pattern"}
  end

  ## Private Functions

  defp resolve_directory(directory, workspace_root) do
    if Path.type(directory) == :absolute do
      directory
    else
      Path.join(workspace_root, directory)
      |> Path.expand()
    end
  end

  defp perform_search(pattern, search_dir, file_pattern) do
    # Try ripgrep first (fastest)
    case search_with_ripgrep(pattern, search_dir, file_pattern) do
      {:ok, _} = result ->
        result

      {:error, _} ->
        # Fall back to grep/find
        case search_with_grep(pattern, search_dir, file_pattern) do
          {:ok, _} = result ->
            result

          {:error, _} ->
            # Fall back to pure Elixir
            search_with_elixir(pattern, search_dir, file_pattern)
        end
    end
  end

  defp search_with_ripgrep(pattern, search_dir, file_pattern) do
    args =
      [
        "--line-number",
        "--no-heading",
        "--color=never",
        "--max-count=#{@max_results}",
        "--max-columns=#{@max_line_length}"
      ] ++
        if(file_pattern, do: ["--glob", file_pattern], else: []) ++
        [pattern, search_dir]

    case System.cmd("rg", args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, parse_ripgrep_output(output)}

      {_output, 1} ->
        # No matches found
        {:ok, []}

      {_output, _} ->
        {:error, :ripgrep_failed}
    end
  rescue
    _e -> {:error, :ripgrep_not_available}
  end

  defp search_with_grep(pattern, search_dir, file_pattern) do
    find_args =
      [search_dir, "-type", "f"] ++
        if(file_pattern, do: ["-name", file_pattern], else: [])

    with {find_output, 0} <- System.cmd("find", find_args),
         files <- String.split(find_output, "\n", trim: true),
         {grep_output, _} <-
           System.cmd("grep", ["-n", "-H", pattern] ++ files, stderr_to_stdout: true) do
      {:ok, parse_grep_output(grep_output)}
    else
      _ -> {:error, :grep_failed}
    end
  rescue
    _e -> {:error, :grep_not_available}
  end

  defp search_with_elixir(pattern, search_dir, file_pattern) do
    try do
      regex = Regex.compile!(pattern)
      glob = if file_pattern, do: file_pattern, else: "**/*"

      results =
        Path.join(search_dir, glob)
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.flat_map(&search_file(&1, regex))
        |> Enum.take(@max_results)

      {:ok, results}
    rescue
      e -> {:error, "Search failed: #{Exception.message(e)}"}
    end
  end

  defp search_file(file_path, regex) do
    case File.read(file_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
        |> Enum.map(fn {line, line_num} ->
          %{
            file: file_path,
            line_number: line_num,
            content: truncate_line(line)
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp parse_ripgrep_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_ripgrep_line/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_results)
  end

  defp parse_ripgrep_line(line) do
    case String.split(line, ":", parts: 3) do
      [file, line_num, content] ->
        %{
          file: file,
          line_number: String.to_integer(line_num),
          content: truncate_line(content)
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp parse_grep_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_grep_line/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_results)
  end

  defp parse_grep_line(line) do
    case String.split(line, ":", parts: 3) do
      [file, line_num, content] ->
        %{
          file: file,
          line_number: String.to_integer(line_num),
          content: truncate_line(content)
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp truncate_line(line) when byte_size(line) > @max_line_length do
    binary_part(line, 0, @max_line_length) <> "..."
  end

  defp truncate_line(line), do: line

  defp format_results([], _workspace_root) do
    {:ok, "No matches found."}
  end

  defp format_results(results, workspace_root) do
    formatted =
      results
      |> Enum.map(fn %{file: file, line_number: line_num, content: content} ->
        relative_path = Path.relative_to(file, workspace_root)
        "#{relative_path}:#{line_num}: #{String.trim(content)}"
      end)
      |> Enum.join("\n")

    count_msg =
      if length(results) >= @max_results do
        "\n\n(Showing first #{@max_results} results, more may exist)"
      else
        ""
      end

    {:ok, "Found #{length(results)} match(es):\n#{formatted}#{count_msg}"}
  end
end
