defmodule Quicksilver.RepositoryMap.Graph.Builder do
  @moduledoc """
  Builds call/dependency graph from parsed entities.
  """
  alias Quicksilver.RepositoryMap.Parser.Entity
  require Logger

  @doc """
  Build a directed graph from entities with edges representing relationships.
  """
  @spec build(map()) :: Graph.t()
  def build(entities) do
    graph = Graph.new(type: :directed)

    # Add all entities as vertices
    graph =
      entities
      |> Map.values()
      |> Enum.reduce(graph, fn entity, g ->
        Graph.add_vertex(g, entity.id, entity)
      end)

    # Add edges for relationships
    graph = add_call_edges(graph, entities)
    graph = add_import_edges(graph, entities)
    graph = add_parent_child_edges(graph, entities)

    graph
  end

  defp add_call_edges(graph, entities) do
    Enum.reduce(entities, graph, fn {_id, entity}, g ->
      entity.calls
      |> resolve_calls(entity, entities)
      |> Enum.reduce(g, fn target_id, g2 ->
        if Graph.has_vertex?(g2, target_id) do
          Graph.add_edge(g2, entity.id, target_id, label: :calls)
        else
          g2
        end
      end)
    end)
  end

  defp add_import_edges(graph, entities) do
    Enum.reduce(entities, graph, fn {_id, entity}, g ->
      entity.imports
      |> resolve_imports(entities)
      |> Enum.reduce(g, fn target_id, g2 ->
        if Graph.has_vertex?(g2, target_id) do
          Graph.add_edge(g2, entity.id, target_id, label: :imports)
        else
          g2
        end
      end)
    end)
  end

  defp add_parent_child_edges(graph, entities) do
    Enum.reduce(entities, graph, fn {_id, entity}, g ->
      if entity.parent_id && Map.has_key?(entities, entity.parent_id) do
        Graph.add_edge(g, entity.parent_id, entity.id, label: :contains)
      else
        g
      end
    end)
  end

  defp resolve_calls(calls, context_entity, all_entities) do
    calls
    |> Enum.map(fn call_ref ->
      resolve_reference(call_ref, context_entity, all_entities)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_imports(imports, all_entities) do
    imports
    |> Enum.map(fn import_ref ->
      find_module_entity(import_ref, all_entities)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_reference(ref, context_entity, all_entities) do
    # Try to find the referenced entity
    # 1. Check in same file (local function)
    # 2. Check in imported/used modules
    # 3. Check globally by name

    cond do
      local = find_local_entity(ref, context_entity, all_entities) ->
        local

      global = find_global_entity(ref, all_entities) ->
        global

      true ->
        nil
    end
  end

  defp find_local_entity(ref, context_entity, all_entities) do
    # Look for entities in the same file
    all_entities
    |> Map.values()
    |> Enum.find(fn e ->
      e.file_path == context_entity.file_path &&
        (e.name == ref || String.ends_with?(e.name, "/#{extract_name_arity(ref)}"))
    end)
    |> case do
      nil -> nil
      entity -> entity.id
    end
  end

  defp find_global_entity(ref, all_entities) do
    # Look for entities by full name match or partial match
    all_entities
    |> Map.values()
    |> Enum.find(fn e ->
      e.name == ref ||
        String.ends_with?(e.name, ".#{extract_name_arity(ref)}") ||
        match_module_function?(e.name, ref)
    end)
    |> case do
      nil -> nil
      entity -> entity.id
    end
  end

  defp find_module_entity(module_name, all_entities) do
    all_entities
    |> Map.values()
    |> Enum.find(fn e ->
      e.type == :module && e.name == module_name
    end)
    |> case do
      nil -> nil
      entity -> entity.id
    end
  end

  defp extract_name_arity(ref) do
    # Extract the function name/arity from references like "Module.function/2"
    ref
    |> String.split(".")
    |> List.last()
  end

  defp match_module_function?(entity_name, ref) do
    # Check if ref matches "Module.function/arity" pattern
    case String.split(ref, ".", parts: 2) do
      [_module, function_arity] ->
        String.ends_with?(entity_name, function_arity)

      _ ->
        false
    end
  end
end
