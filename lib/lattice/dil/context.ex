defmodule Lattice.DIL.Context do
  @moduledoc """
  Gathers signals from the repository and GitHub for DIL candidate identification.

  Scans `lib/` and `test/` for code-level signals (TODOs, missing moduledocs,
  missing typespecs, large files, test gaps) and queries GitHub for recent
  closed issues.
  """

  alias Lattice.Capabilities.GitHub

  defstruct todos: [],
            missing_moduledocs: [],
            missing_typespecs: [],
            large_files: [],
            test_gaps: [],
            recent_issues: []

  @type signal :: %{file: String.t(), line: integer() | nil, detail: String.t()}

  @type t :: %__MODULE__{
          todos: [signal()],
          missing_moduledocs: [signal()],
          missing_typespecs: [signal()],
          large_files: [signal()],
          test_gaps: [signal()],
          recent_issues: [map()]
        }

  @large_file_threshold 300

  @doc """
  Gather all context signals. Returns a `%Context{}` struct.
  """
  @spec gather() :: t()
  def gather do
    lib_files = list_project_files()
    test_files = list_elixir_files("test")

    %__MODULE__{
      todos: scan_todos(lib_files),
      missing_moduledocs: scan_missing_moduledocs(lib_files),
      missing_typespecs: scan_missing_typespecs(lib_files),
      large_files: scan_large_files(lib_files),
      test_gaps: scan_test_gaps(lib_files, test_files),
      recent_issues: fetch_recent_issues()
    }
  end

  # ── File Scanning ────────────────────────────────────────────────────

  # In a release, `lib/` contains compiled dependencies alongside project code.
  # Scope to project directories only to avoid scanning framework templates.
  defp list_project_files do
    ~w(lib/lattice lib/lattice_web lib/mix)
    |> Enum.flat_map(fn dir ->
      Path.wildcard(Path.join(dir, "**/*.ex")) ++
        Path.wildcard(Path.join(dir, "**/*.exs"))
    end)
  end

  defp list_elixir_files(dir) do
    Path.wildcard(Path.join(dir, "**/*.ex")) ++
      Path.wildcard(Path.join(dir, "**/*.exs"))
  end

  defp scan_todos(files) do
    Enum.flat_map(files, fn file ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> line =~ ~r/# TODO/i end)
      |> Enum.map(fn {line, num} ->
        %{file: file, line: num, detail: String.trim(line)}
      end)
    end)
  end

  defp scan_missing_moduledocs(files) do
    files
    |> Enum.filter(fn file ->
      String.ends_with?(file, ".ex") and
        (
          content = File.read!(file)
          has_defmodule?(content) and not has_moduledoc?(content)
        )
    end)
    |> Enum.map(fn file ->
      %{file: file, line: nil, detail: "missing @moduledoc"}
    end)
  end

  defp scan_missing_typespecs(files) do
    files
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.flat_map(fn file ->
      content = File.read!(file)

      if has_public_functions?(content) and not has_typespecs?(content) do
        [%{file: file, line: nil, detail: "public functions without @spec"}]
      else
        []
      end
    end)
  end

  defp scan_large_files(files) do
    Enum.flat_map(files, fn file ->
      line_count = file |> File.read!() |> String.split("\n") |> length()

      if line_count > @large_file_threshold do
        [%{file: file, line: nil, detail: "#{line_count} lines"}]
      else
        []
      end
    end)
  end

  defp scan_test_gaps(lib_files, test_files) do
    test_modules =
      test_files
      |> Enum.map(&Path.basename/1)
      |> MapSet.new()

    lib_files
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.reject(&(&1 =~ ~r/(application|router|endpoint|telemetry|gettext|error)/))
    |> Enum.filter(fn file ->
      expected_test = file |> Path.basename(".ex") |> Kernel.<>("_test.exs")
      expected_test not in test_modules
    end)
    |> Enum.map(fn file ->
      %{file: file, line: nil, detail: "no corresponding test file"}
    end)
  end

  # ── GitHub Signals ───────────────────────────────────────────────────

  defp fetch_recent_issues do
    case GitHub.list_issues(state: "closed", per_page: 20) do
      {:ok, issues} -> issues
      {:error, _} -> []
    end
  end

  # ── Content Helpers ──────────────────────────────────────────────────

  defp has_defmodule?(content), do: content =~ ~r/defmodule\s+/
  defp has_moduledoc?(content), do: content =~ ~r/@moduledoc/
  defp has_public_functions?(content), do: content =~ ~r/\n\s+def\s+\w+/
  defp has_typespecs?(content), do: content =~ ~r/@spec\s+/
end
