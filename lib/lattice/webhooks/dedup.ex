defmodule Lattice.Webhooks.Dedup do
  @moduledoc """
  ETS-backed webhook event deduplication.

  Tracks delivery IDs from the `X-GitHub-Delivery` header to prevent
  double-processing when GitHub retries webhook deliveries. Each entry
  has a configurable TTL (default: 5 minutes).

  ## Design

  - ETS table: `:set`, `:public`, `:named_table`
  - Uses `:erlang.monotonic_time(:millisecond)` for expiry to avoid wall-clock drift
  - Periodic sweep every TTL interval removes expired entries
  - Public table allows direct reads without GenServer bottleneck
  """

  use GenServer

  @table_name :lattice_webhook_dedup

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Check if a delivery ID has already been seen.

  Returns `true` if the delivery has been processed before (duplicate),
  `false` if it's new. Automatically records the delivery ID.
  """
  @spec seen?(String.t()) :: boolean()
  def seen?(delivery_id) when is_binary(delivery_id) do
    now = :erlang.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, delivery_id) do
      [{^delivery_id, _expires_at}] ->
        true

      [] ->
        ttl = ttl_ms()
        :ets.insert(@table_name, {delivery_id, now + ttl})
        false
    end
  end

  @doc """
  Reset the dedup table. Intended for test cleanup only.
  """
  def reset do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table_name, [:set, :public, :named_table])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep_expired(state.table)
    schedule_sweep()
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp sweep_expired(table) do
    now = :erlang.monotonic_time(:millisecond)

    :ets.foldl(
      fn {id, expires_at}, acc ->
        if expires_at < now, do: :ets.delete(table, id)
        acc
      end,
      :ok,
      table
    )
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, ttl_ms())
  end

  defp ttl_ms do
    :lattice
    |> Application.get_env(:webhooks, [])
    |> Keyword.get(:dedup_ttl_ms, :timer.minutes(5))
  end
end
