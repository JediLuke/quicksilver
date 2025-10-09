defmodule Quicksilver.Tools.RunTests do
  @moduledoc """
  Tool for running Elixir tests and returning results.
  """

  @behaviour Quicksilver.Tools.Behaviour

  @impl true
  def name, do: "run_tests"

  @impl true
  def description do
    """
    Run tests for the project or specific test file.
    Returns test results including failures that can be used to fix code.
    """
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Specific test file path (optional, runs all tests if not provided)"
        }
      }
    }
  end

  @impl true
  def execute(args, context) do
    workspace_root = Map.get(context, :workspace_root, File.cwd!())
    test_args = if args["path"], do: [args["path"]], else: []

    case System.cmd("mix", ["test"] ++ test_args,
                    cd: workspace_root,
                    stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, "✅ Tests passed!\n\n#{output}"}

      {output, _exit_code} ->
        parsed = parse_test_failures(output)
        {:ok, "❌ Tests failed:\n\n#{output}\n\n#{parsed}"}
    end
  end

  defp parse_test_failures(output) do
    # Extract useful failure information
    failures =
      output
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, ["** (", "Assertion with"]))
      |> Enum.join("\n")

    if failures != "" do
      "Parsed failures for fixing:\n#{failures}"
    else
      ""
    end
  end
end
