defmodule Quicksilver.Approval.Policy do
  @moduledoc """
  Configurable approval policies for dangerous operations.
  """

  defstruct mode: :manual,              # :manual, :auto, :readonly
            auto_approve_list: [],      # Tools that don't need approval
            max_auto_size: 1000,        # Max bytes for auto-approve
            whitelist_patterns: [],     # File patterns to allow
            blacklist_patterns: ["**/.git/**", "**/node_modules/**"]

  @type t :: %__MODULE__{}

  @doc """
  Returns the default approval policy with read-only tools auto-approved.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      auto_approve_list: ["read_file", "search_files", "list_files"],
      mode: :manual
    }
  end

  @doc """
  Determines if a tool operation should request approval from the user.
  """
  @spec should_request_approval?(t(), String.t(), map()) :: boolean()
  def should_request_approval?(policy, tool_name, _args) do
    not (tool_name in policy.auto_approve_list)
  end
end
