defmodule Lattice.Capabilities.Fly.Live do
  @moduledoc """
  Live implementation of the Fly capability backed by the `fly` CLI.

  Uses `System.cmd("fly", ...)` to call the Fly.io CLI (`flyctl`), which
  handles authentication via its own token config. This avoids managing
  API tokens directly and works on any machine where `fly auth login` has
  been run or where `FLY_API_TOKEN` is set.

  ## Configuration

  The target Fly app is read from `Lattice.Instance.resource(:fly_app)`.
  All operations are scoped to this app.

  ## Safety

  Read operations (`machine_status/1`, `logs/1`) are implemented.
  The `deploy/1` operation is classified as `:dangerous` by the safety
  classifier and is not implemented here -- it returns an error directing
  the operator to use `fly deploy` directly.

  ## Telemetry

  Every Fly CLI call emits a `[:lattice, :capability, :call]` telemetry
  event via `Lattice.Events.emit_capability_call/4` with:

  - capability: `:fly`
  - operation: the callback name (e.g., `:machine_status`)
  - duration_ms: wall-clock time of the `fly` CLI call
  - result: `:ok` or `{:error, reason}`
  """

  @behaviour Lattice.Capabilities.Fly

  require Logger

  alias Lattice.Events

  # ── Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def deploy(_config) do
    Logger.warning("Fly deploy is classified as dangerous and is not implemented in Fly.Live")
    {:error, :not_implemented}
  end

  @impl true
  def machine_status(machine_id) do
    timed_cmd(:machine_status, ["machine", "status", machine_id, "--json"], fn json ->
      case Jason.decode(json) do
        {:ok, data} when is_map(data) ->
          {:ok, parse_machine_status(data)}

        {:error, _} ->
          {:error, {:invalid_json, json}}
      end
    end)
  end

  @impl true
  def logs(machine_id, opts) do
    args = build_logs_args(machine_id, opts)

    timed_cmd(:logs, args, fn output ->
      lines =
        output
        |> String.split("\n", trim: true)

      {:ok, lines}
    end)
  end

  # ── Private: fly CLI Execution ──────────────────────────────────────────

  defp timed_cmd(operation, args, on_success) do
    app = app()
    full_args = args ++ ["--app", app]

    start_time = System.monotonic_time(:millisecond)

    result = run_fly(full_args)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, output} ->
        case on_success.(output) do
          {:ok, _} = success ->
            Events.emit_capability_call(:fly, operation, duration_ms, :ok)
            success

          {:error, _} = error ->
            Events.emit_capability_call(:fly, operation, duration_ms, error)
            error
        end

      {:error, reason} = error ->
        Events.emit_capability_call(:fly, operation, duration_ms, error)
        Logger.error("Fly #{operation} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_fly(args) do
    Logger.debug("fly #{Enum.join(args, " ")}")

    try do
      case System.cmd("fly", args, stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, String.trim(output)}

        {output, exit_code} ->
          parse_fly_error(output, exit_code)
      end
    rescue
      e in ErlangError ->
        Logger.error("Failed to execute fly CLI: #{inspect(e)}")
        {:error, :fly_not_found}
    end
  end

  defp parse_fly_error(output, _exit_code) do
    cond do
      String.contains?(output, "not found") or
          String.contains?(output, "could not find") ->
        {:error, :not_found}

      String.contains?(output, "not authenticated") or
        String.contains?(output, "unauthorized") or
          String.contains?(output, "401") ->
        {:error, :unauthorized}

      true ->
        {:error, {:fly_error, String.trim(output)}}
    end
  end

  # ── Private: Argument Building ─────────────────────────────────────────

  defp build_logs_args(machine_id, opts) do
    args = ["machine", "logs", machine_id]

    args =
      case Keyword.get(opts, :lines) do
        nil -> args
        n -> args ++ ["--lines", to_string(n)]
      end

    case Keyword.get(opts, :region) do
      nil -> args
      region -> args ++ ["--region", region]
    end
  end

  # ── Private: Parsing ───────────────────────────────────────────────────

  @doc false
  def parse_machine_status(data) when is_map(data) do
    %{
      machine_id: data["id"] || data["machine_id"],
      state: data["state"] || "unknown",
      region: data["region"],
      image: get_in(data, ["config", "image"]) || data["image"],
      created_at: data["created_at"],
      checks: parse_checks(data["checks"] || [])
    }
  end

  defp parse_checks(checks) when is_list(checks) do
    Enum.map(checks, fn check ->
      %{
        name: check["name"] || "unknown",
        status: check["status"] || "unknown"
      }
    end)
  end

  defp parse_checks(_), do: []

  # ── Private: Configuration ─────────────────────────────────────────────

  defp app do
    Lattice.Instance.resource(:fly_app) ||
      raise "FLY_APP resource binding is not configured. " <>
              "Set the FLY_APP environment variable."
  end
end
