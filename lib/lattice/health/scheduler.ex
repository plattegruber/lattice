defmodule Lattice.Health.Scheduler do
  @moduledoc """
  Runs configurable health checks on a schedule.

  Supports multiple check types that emit observations when failures
  are detected. These observations flow through the existing
  Health.Detector → Intent pipeline.

  ## Check Types

  - `:http_probe` — HTTP GET to a URL, checks for 2xx response
  - `:fleet_health` — Aggregates sprite states, detects unhealthy fleet ratios

  ## Configuration

      config :lattice, Lattice.Health.Scheduler,
        enabled: true,
        checks: [
          %{type: :http_probe, name: "app_health", url: "https://example.com/health",
            interval_ms: 30_000, timeout_ms: 5_000, severity: :high},
          %{type: :fleet_health, name: "fleet", interval_ms: 60_000,
            unhealthy_threshold: 0.5, severity: :critical}
        ]
  """

  use GenServer

  require Logger

  alias Lattice.Events
  alias Lattice.Intents.Observation
  alias Lattice.Sprites.FleetManager

  @default_interval_ms :timer.seconds(30)

  # ── Public API ──────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current check schedule and last results."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    checks = config(:checks, [])

    state =
      Enum.reduce(checks, %{checks: [], results: %{}}, fn check, acc ->
        check = normalize_check(check)
        schedule_check(check)
        %{acc | checks: [check | acc.checks]}
      end)

    {:ok, %{state | checks: Enum.reverse(state.checks)}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{checks: state.checks, results: state.results}, state}
  end

  @impl true
  def handle_info({:run_check, check_name}, state) do
    case find_check(state.checks, check_name) do
      nil ->
        {:noreply, state}

      check ->
        result = run_check(check)
        state = put_in(state, [:results, check_name], result)

        if result.status == :failure do
          emit_health_observation(check, result)
        end

        schedule_check(check)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Check Execution ─────────────────────────────────────────────

  defp run_check(%{type: :http_probe} = check) do
    url = Map.fetch!(check, :url)
    timeout = Map.get(check, :timeout_ms, 5_000)

    case http_get(url, timeout) do
      {:ok, status_code} when status_code >= 200 and status_code < 300 ->
        %{status: :ok, details: "HTTP #{status_code}", checked_at: DateTime.utc_now()}

      {:ok, status_code} ->
        %{
          status: :failure,
          details: "HTTP #{status_code}",
          checked_at: DateTime.utc_now()
        }

      {:error, reason} ->
        %{
          status: :failure,
          details: "#{inspect(reason)}",
          checked_at: DateTime.utc_now()
        }
    end
  end

  defp run_check(%{type: :fleet_health} = check) do
    threshold = Map.get(check, :unhealthy_threshold, 0.5)

    try do
      summary = FleetManager.fleet_summary()
      total = summary.total

      if total == 0 do
        %{status: :ok, details: "No sprites", checked_at: DateTime.utc_now()}
      else
        healthy =
          Enum.reduce(summary.by_state, 0, fn
            {state, count}, acc when state in [:ready, :warm, :running] -> acc + count
            _, acc -> acc
          end)

        ratio = healthy / total

        if ratio < threshold do
          %{
            status: :failure,
            details:
              "#{round(ratio * 100)}% healthy (#{healthy}/#{total}), threshold: #{round(threshold * 100)}%",
            checked_at: DateTime.utc_now()
          }
        else
          %{
            status: :ok,
            details: "#{round(ratio * 100)}% healthy (#{healthy}/#{total})",
            checked_at: DateTime.utc_now()
          }
        end
      end
    rescue
      error ->
        %{
          status: :failure,
          details: "Fleet check error: #{inspect(error)}",
          checked_at: DateTime.utc_now()
        }
    end
  end

  defp run_check(%{type: type}) do
    %{status: :failure, details: "Unknown check type: #{type}", checked_at: DateTime.utc_now()}
  end

  # ── Observation Emission ────────────────────────────────────────

  defp emit_health_observation(check, result) do
    severity = Map.get(check, :severity, :high)

    {:ok, obs} =
      Observation.new("health-scheduler", :anomaly,
        severity: severity,
        data: %{
          "message" => "Health check failed: #{check.name}",
          "check_name" => check.name,
          "check_type" => to_string(check.type),
          "details" => result.details,
          "category" => "health_check_#{check.name}"
        }
      )

    Events.broadcast_observation(obs)
  end

  # ── Scheduling ──────────────────────────────────────────────────

  defp schedule_check(check) do
    interval = Map.get(check, :interval_ms, @default_interval_ms)
    Process.send_after(self(), {:run_check, check.name}, interval)
  end

  defp find_check(checks, name) do
    Enum.find(checks, &(&1.name == name))
  end

  # ── Normalization ───────────────────────────────────────────────

  defp normalize_check(check) when is_map(check) do
    check
    |> Map.put_new(:interval_ms, @default_interval_ms)
    |> Map.put_new(:severity, :high)
  end

  # ── HTTP Client ─────────────────────────────────────────────────

  defp http_get(url, timeout) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, timeout}], []) do
      {:ok, {{_, status_code, _}, _headers, _body}} ->
        {:ok, status_code}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Config ──────────────────────────────────────────────────────

  defp config(key, default) do
    Application.get_env(:lattice, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
