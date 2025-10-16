defmodule Quicksilver.RepositoryMap.Parser.Entity do
  @moduledoc """
  Entity representation for code elements (modules, functions, macros, etc.)
  """

  @enforce_keys [:id, :name, :type, :file_path, :line_start, :line_end]
  defstruct [
    :id,
    :name,
    :type,
    :file_path,
    :line_start,
    :line_end,
    :signature,
    :doc,
    :parent_id,
    imports: [],
    calls: [],
    refs: [],
    children_ids: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          type: atom(),
          file_path: String.t(),
          line_start: integer(),
          line_end: integer(),
          signature: String.t() | nil,
          doc: String.t() | nil,
          parent_id: String.t() | nil,
          imports: list(String.t()),
          calls: list(String.t()),
          refs: list(String.t()),
          children_ids: list(String.t()),
          metadata: map()
        }

  @doc """
  Build a unique ID for an entity based on file path, name, and type.
  """
  @spec build_id(String.t(), String.t(), atom()) :: String.t()
  def build_id(file_path, name, type) do
    :crypto.hash(:md5, "#{file_path}:#{name}:#{type}")
    |> Base.encode16(case: :lower)
    |> String.slice(0..15)
  end
end
