defmodule Quicksilver.RepositoryMap.Formatter.LLM do
  @moduledoc """
  Formats repository map for LLM consumption.
  Creates a token-efficient representation of the codebase.
  """
  alias Quicksilver.RepositoryMap.Parser.Entity

  @default_token_limit 4000

  @doc """
  Format repository map for LLM context.

  ## Options
    - `:token_limit` - Maximum tokens in output (default: 4000)
    - `:focus_files` - List of files to prioritize
    - `:focus_keywords` - List of keywords to prioritize entities
  """
  @spec format(map(), keyword()) :: String.t()
  def format(repository_map, opts \\ []) do
    token_limit = Keyword.get(opts, :token_limit, @default_token_limit)
    focus_keywords = Keyword.get(opts, :focus_keywords, [])

    # Filter and score entities based on focus
    scored_entities = score_entities(repository_map, focus_keywords)

    output =
      []
      |> add_summary(repository_map)
      |> add_key_entities(scored_entities, repository_map)
      |> add_file_structure(repository_map)
      |> Enum.join("\n")

    trim_to_token_limit(output, token_limit)
  end

  defp score_entities(%{entities: entities, scores: scores}, focus_keywords) do
    entities
    |> Map.values()
    |> Enum.map(fn entity ->
      base_score = Map.get(scores, entity.id, 0.0)
      keyword_boost = calculate_keyword_score(entity, focus_keywords)
      final_score = base_score + keyword_boost
      {entity, final_score}
    end)
    |> Enum.sort_by(fn {_entity, score} -> score end, :desc)
  end

  defp calculate_keyword_score(_entity, []), do: 0.0

  defp calculate_keyword_score(entity, keywords) do
    Enum.reduce(keywords, 0.0, fn keyword, acc ->
      score = 0.0

      score = if String.contains?(String.downcase(entity.name), keyword), do: score + 2.0, else: score

      score = if entity.signature && String.contains?(String.downcase(entity.signature), keyword),
        do: score + 1.5,
        else: score

      score = if entity.doc && String.contains?(String.downcase(entity.doc), keyword),
        do: score + 1.0,
        else: score

      score = if String.contains?(String.downcase(entity.file_path), keyword),
        do: score + 0.5,
        else: score

      acc + score
    end)
  end

  defp add_summary(sections, %{stats: stats}) do
    summary = """
    # Repository Map

    ## Summary
    - Total Entities: #{stats.total_entities}
    - Total Files: #{stats.total_files}
    - Average Entity Size: #{Float.round(stats.avg_entity_size, 1)} lines

    ## Entity Types
    #{format_entity_types(stats.entities_by_type)}

    ---
    """

    [summary | sections]
  end

  defp add_key_entities(sections, scored_entities, _repository_map) do
    # Group by file and take top entities
    top_entities =
      scored_entities
      |> Enum.take(50)

    entity_section = """
    ## Key Entities

    #{format_entities_by_file(top_entities)}
    """

    sections ++ [entity_section]
  end

  defp add_file_structure(sections, %{files: files, entities: entities}) do
    file_tree = build_file_tree(files, entities)

    structure_section = """
    ## File Structure

    ```
    #{format_file_tree(file_tree)}
    ```
    """

    sections ++ [structure_section]
  end

  defp format_entity_types(types) do
    types
    |> Enum.sort_by(fn {_type, count} -> count end, :desc)
    |> Enum.map(fn {type, count} ->
      "- #{String.capitalize(to_string(type))}: #{count}"
    end)
    |> Enum.join("\n")
  end

  defp format_entities_by_file(entities_with_scores) do
    entities_with_scores
    |> Enum.group_by(fn {entity, _score} -> entity.file_path end)
    |> Enum.sort_by(
      fn {_file, entities} ->
        entities
        |> Enum.map(fn {_e, score} -> score end)
        |> Enum.sum()
      end,
      :desc
    )
    |> Enum.take(20)
    |> Enum.map(fn {file, entities} ->
      """
      ### #{file}

      #{format_file_entities(entities)}
      """
    end)
    |> Enum.join("\n")
  end

  defp format_file_entities(entities) do
    entities
    |> Enum.sort_by(fn {_entity, score} -> score end, :desc)
    |> Enum.take(5)
    |> Enum.map(fn {entity, score} ->
      score_indicator =
        cond do
          score > 0.7 -> "⭐⭐⭐"
          score > 0.4 -> "⭐⭐"
          true -> "⭐"
        end

      doc_snippet =
        if entity.doc do
          entity.doc
          |> String.split("\n")
          |> List.first()
          |> String.slice(0, 80)
          |> then(fn s -> "\n  > #{s}" end)
        else
          ""
        end

      "- **#{entity.name}** #{score_indicator} `#{entity.signature || entity.type}`#{doc_snippet}"
    end)
    |> Enum.join("\n")
  end

  defp build_file_tree(files, entities) do
    tree = %{}

    Enum.reduce(files, tree, fn file, acc ->
      parts = Path.split(file)
      put_in_tree(acc, parts, count_entities_in_file(entities, file))
    end)
  end

  defp put_in_tree(tree, [part], entity_count) do
    Map.put(tree, part, {:file, entity_count})
  end

  defp put_in_tree(tree, [part | rest], entity_count) do
    subtree = Map.get(tree, part, %{})
    Map.put(tree, part, put_in_tree(subtree, rest, entity_count))
  end

  defp count_entities_in_file(entities, file) do
    entities
    |> Map.values()
    |> Enum.count(fn e -> e.file_path == file end)
  end

  defp format_file_tree(tree, indent \\ "") do
    tree
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn
      {name, {:file, count}} ->
        "#{indent}#{name} (#{count} entities)"

      {name, subtree} when is_map(subtree) ->
        "#{indent}#{name}/\n" <> format_file_tree(subtree, indent <> "  ")
    end)
    |> Enum.join("\n")
  end

  defp trim_to_token_limit(text, limit) do
    # Rough approximation: 1 token ≈ 4 characters
    estimated_tokens = String.length(text) / 4

    if estimated_tokens <= limit do
      text
    else
      char_limit = trunc(limit * 4)

      String.slice(text, 0, char_limit - 100) <>
        "\n\n[... Repository map truncated to fit token limit ...]"
    end
  end
end
