defmodule Quicksilver.RepositoryMap.Parser.RepositoryParser do
  @moduledoc """
  Parses entire repository into entities using concurrent processing.
  """
  require Logger
  alias Quicksilver.RepositoryMap.Parser.{Entity, ElixirParser}

  @type parse_result :: %{
          entities: %{String.t() => Entity.t()},
          files: list(String.t()),
          stats: map()
        }

  @doc """
  Parse a repository at the given path.

  ## Options
    - `:extensions` - List of file extensions to parse (default: [".ex", ".exs"])
    - `:ignore_patterns` - List of patterns to ignore (default: reads .gitignore)
    - `:max_concurrency` - Maximum concurrent parsers (default: System.schedulers_online())
  """
  @spec parse(String.t(), keyword()) :: {:ok, parse_result()} | {:error, term()}
  def parse(repo_path, opts \\ []) do
    with {:ok, files} <- get_source_files(repo_path, opts),
         entities <- parse_files_concurrent(files, repo_path, opts),
         stats <- calculate_stats(entities, files) do
      {:ok,
       %{
         entities: entities,
         files: files,
         stats: stats
       }}
    end
  end

  defp get_source_files(repo_path, opts) do
    extensions = Keyword.get(opts, :extensions, [".ex", ".exs"])
    ignore_patterns = load_gitignore(repo_path)

    files =
      Path.wildcard(Path.join(repo_path, "**/*"))
      |> Stream.filter(&File.regular?/1)
      |> Stream.filter(fn path ->
        ext = Path.extname(path)
        ext in extensions and not ignored?(path, ignore_patterns)
      end)
      |> Enum.to_list()

    {:ok, files}
  end

  defp parse_files_concurrent(files, repo_path, opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    # Use Flow for parallel processing
    files
    |> Flow.from_enumerable(max_demand: 20, stages: max_concurrency)
    |> Flow.map(fn file ->
      parse_single_file(file, repo_path)
    end)
    |> Flow.reduce(fn -> %{} end, fn entities, acc ->
      Map.merge(acc, entities)
    end)
    |> Enum.into(%{})
  end

  defp parse_single_file(file_path, repo_path) do
    relative_path = Path.relative_to(file_path, repo_path)

    try do
      content = File.read!(file_path)
      ElixirParser.parse(content, relative_path)
    rescue
      e ->
        Logger.warning("Failed to parse #{file_path}: #{inspect(e)}")
        %{}
    end
  end

  defp load_gitignore(repo_path) do
    gitignore_path = Path.join(repo_path, ".gitignore")

    default_patterns = [
      ~r/_build/,
      ~r/deps/,
      ~r/\.elixir_ls/,
      ~r/\.fetch/,
      ~r/erl_crash\.dump/,
      ~r/.*\.ez$/,
      ~r/.*\.beam$/,
      ~r/config\/.*\.secret\.exs$/
    ]

    if File.exists?(gitignore_path) do
      file_patterns =
        gitignore_path
        |> File.read!()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> Enum.map(&compile_pattern/1)

      default_patterns ++ file_patterns
    else
      default_patterns
    end
  end

  defp compile_pattern(pattern) do
    pattern
    |> String.replace("*", ".*")
    |> String.replace("?", ".")
    |> then(fn p -> ~r/#{p}/ end)
  rescue
    _ -> ~r/^$/
  end

  defp ignored?(path, patterns) do
    Enum.any?(patterns, &Regex.match?(&1, path))
  end

  defp calculate_stats(entities, files) do
    %{
      total_entities: map_size(entities),
      total_files: length(files),
      entities_by_type: count_by_type(entities),
      entities_by_file: count_by_file(entities),
      avg_entity_size: average_entity_size(entities)
    }
  end

  defp count_by_type(entities) do
    entities
    |> Map.values()
    |> Enum.group_by(& &1.type)
    |> Map.new(fn {type, list} -> {type, length(list)} end)
  end

  defp count_by_file(entities) do
    entities
    |> Map.values()
    |> Enum.group_by(& &1.file_path)
    |> Map.new(fn {file, list} -> {file, length(list)} end)
  end

  defp average_entity_size(entities) do
    sizes =
      entities
      |> Map.values()
      |> Enum.map(fn e -> e.line_end - e.line_start + 1 end)

    if sizes == [] do
      0
    else
      Enum.sum(sizes) / length(sizes)
    end
  end
end
