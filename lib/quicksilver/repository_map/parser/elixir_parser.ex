defmodule Quicksilver.RepositoryMap.Parser.ElixirParser do
  @moduledoc """
  Elixir-specific parsing using AST (Code.string_to_quoted)
  """
  alias Quicksilver.RepositoryMap.Parser.Entity

  @doc """
  Parse Elixir code content and extract entities.
  """
  @spec parse(String.t(), String.t()) :: %{String.t() => Entity.t()}
  def parse(content, file_path) do
    case Code.string_to_quoted(content, columns: true, token_metadata: true) do
      {:ok, ast} ->
        extract_entities(ast, file_path)

      {:error, _} ->
        %{}
    end
  end

  defp extract_entities(ast, file_path) do
    {_ast, entities} =
      Macro.prewalk(ast, %{}, fn node, acc ->
        case extract_entity(node, file_path) do
          nil -> {node, acc}
          entity -> {node, Map.put(acc, entity.id, entity)}
        end
      end)

    entities
  end

  # Extract defmodule
  defp extract_entity({:defmodule, meta, [module_alias | rest]}, file_path) do
    name = module_name(module_alias)

    %Entity{
      id: Entity.build_id(file_path, name, :module),
      name: name,
      type: :module,
      file_path: file_path,
      line_start: meta[:line] || 1,
      line_end: find_end_line(rest, meta[:line]),
      signature: "defmodule #{name}",
      doc: extract_doc(rest),
      imports: extract_uses_and_imports(rest),
      metadata: %{
        behaviours: extract_behaviours(rest),
        attributes: extract_attributes(rest)
      }
    }
  end

  # Extract def/defp/defmacro/defmacrop
  defp extract_entity({def_type, meta, [{name, _, args} | rest]}, file_path)
       when def_type in [:def, :defp, :defmacro, :defmacrop] do
    visibility = if def_type in [:def, :defmacro], do: :public, else: :private
    type = if def_type in [:defmacro, :defmacrop], do: :macro, else: :function
    arity = if is_list(args), do: length(args), else: 0

    %Entity{
      id: Entity.build_id(file_path, "#{name}/#{arity}", type),
      name: "#{name}/#{arity}",
      type: type,
      file_path: file_path,
      line_start: meta[:line] || 1,
      line_end: find_end_line(rest, meta[:line]),
      signature: build_function_signature(def_type, name, args),
      doc: extract_doc(rest),
      calls: extract_function_calls(rest),
      metadata: %{
        visibility: visibility,
        arity: arity,
        raw_name: name
      }
    }
  end

  # Extract defstruct
  defp extract_entity({:defstruct, meta, [fields]}, file_path) do
    %Entity{
      id: Entity.build_id(file_path, "struct", :struct),
      name: "struct",
      type: :struct,
      file_path: file_path,
      line_start: meta[:line] || 1,
      line_end: meta[:line] || 1,
      signature: "defstruct #{inspect(fields)}",
      metadata: %{
        fields: extract_struct_fields(fields)
      }
    }
  end

  # Extract defprotocol
  defp extract_entity({:defprotocol, meta, [name | rest]}, file_path) do
    protocol_name = module_name(name)

    %Entity{
      id: Entity.build_id(file_path, protocol_name, :protocol),
      name: protocol_name,
      type: :protocol,
      file_path: file_path,
      line_start: meta[:line] || 1,
      line_end: find_end_line(rest, meta[:line]),
      signature: "defprotocol #{protocol_name}",
      doc: extract_doc(rest)
    }
  end

  # Extract defimpl
  defp extract_entity({:defimpl, meta, [protocol_name, [for: for_type] | rest]}, file_path) do
    protocol = module_name(protocol_name)
    impl_for = module_name(for_type)
    name = "#{protocol} for #{impl_for}"

    %Entity{
      id: Entity.build_id(file_path, name, :impl),
      name: name,
      type: :impl,
      file_path: file_path,
      line_start: meta[:line] || 1,
      line_end: find_end_line(rest, meta[:line]),
      signature: "defimpl #{protocol}, for: #{impl_for}",
      doc: extract_doc(rest),
      metadata: %{
        protocol: protocol,
        for: impl_for
      }
    }
  end

  defp extract_entity(_node, _file_path), do: nil

  # Helper functions

  defp module_name({:__aliases__, _, parts}) do
    Enum.map_join(parts, ".", &to_string/1)
  end

  defp module_name(atom) when is_atom(atom), do: to_string(atom)
  defp module_name(_), do: "Unknown"

  defp build_function_signature(def_type, name, args) when is_list(args) do
    arg_str =
      args
      |> Enum.map(&format_arg/1)
      |> Enum.join(", ")

    "#{def_type} #{name}(#{arg_str})"
  end

  defp build_function_signature(def_type, name, _), do: "#{def_type} #{name}()"

  defp format_arg({name, _, _}) when is_atom(name), do: to_string(name)
  defp format_arg({:\\, _, [{name, _, _}, _default]}), do: "#{name} \\\\ default"
  defp format_arg(_), do: "_"

  defp extract_function_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        # Module.function(args) calls
        {{:., _, [module, function]}, _, args}, acc when is_list(args) ->
          call = "#{module_name(module)}.#{function}/#{length(args)}"
          {nil, [call | acc]}

        # Local function(args) calls
        {function, _, args}, acc when is_atom(function) and is_list(args) ->
          call = "#{function}/#{length(args)}"
          {nil, [call | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(calls)
  end

  defp extract_uses_and_imports(ast) do
    {_ast, imports} =
      Macro.prewalk(ast, [], fn
        {:use, _, [module | _]}, acc ->
          {nil, [module_name(module) | acc]}

        {:import, _, [module | _]}, acc ->
          {nil, [module_name(module) | acc]}

        {:alias, _, [module | _]}, acc ->
          {nil, [module_name(module) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(imports)
  end

  defp extract_behaviours(ast) do
    {_ast, behaviours} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:behaviour, _, [module]}]}, acc ->
          {nil, [module_name(module) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(behaviours)
  end

  defp extract_attributes(_ast) do
    # Could extract @moduledoc, @doc, custom attributes, etc.
    %{}
  end

  defp extract_doc(ast) do
    # Try to find @moduledoc or @doc in the AST
    {_ast, doc} =
      Macro.prewalk(ast, nil, fn
        {:@, _, [{:moduledoc, _, [doc_string]}]}, _acc when is_binary(doc_string) ->
          {nil, doc_string}

        {:@, _, [{:doc, _, [doc_string]}]}, _acc when is_binary(doc_string) ->
          {nil, doc_string}

        node, acc ->
          {node, acc}
      end)

    doc
  end

  defp find_end_line([{:do, block} | _], start_line) do
    # Walk the block to find the last line
    max_line =
      Macro.prewalk(block, start_line, fn
        {_, meta, _}, acc when is_list(meta) ->
          line = meta[:line] || acc
          {nil, max(line, acc)}

        node, acc ->
          {node, acc}
      end)

    case max_line do
      {_, line} -> line
      line when is_integer(line) -> line
      _ -> start_line + 10
    end
  end

  defp find_end_line(_ast, start_line), do: start_line + 10

  defp extract_struct_fields(fields) when is_list(fields) do
    Enum.map(fields, fn
      {name, _default} -> to_string(name)
      name when is_atom(name) -> to_string(name)
      _ -> "unknown"
    end)
  end

  defp extract_struct_fields(_), do: []
end
