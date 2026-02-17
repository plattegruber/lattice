defmodule Lattice.Sprites.SpriteObservationTest do
  use ExUnit.Case

  @moduletag :unit

  import Mox

  alias Lattice.Events
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Observation
  alias Lattice.Sprites.Sprite

  setup :set_mox_global
  setup :verify_on_exit!

  @long_interval 60_000

  # ── Helpers ──────────────────────────────────────────────────────

  defp start_sprite(opts \\ []) do
    sprite_id =
      Keyword.get(opts, :sprite_id, "sprite-obs-#{System.unique_integer([:positive])}")

    Lattice.Capabilities.MockSprites
    |> stub(:get_sprite, fn _id -> {:ok, %{id: sprite_id, status: :hibernating}} end)

    defaults = [
      sprite_id: sprite_id,
      reconcile_interval_ms: @long_interval
    ]

    merged = Keyword.merge(defaults, opts)
    {:ok, pid} = Sprite.start_link(merged)
    {pid, sprite_id}
  end

  # ── emit_observation/2 ──────────────────────────────────────────

  describe "emit_observation/2" do
    test "returns {:ok, observation} for valid observation" do
      {pid, sprite_id} = start_sprite()

      assert {:ok, %Observation{} = obs} =
               Sprite.emit_observation(pid, type: :metric, data: %{"cpu" => 42.0})

      assert obs.sprite_id == sprite_id
      assert obs.type == :metric
      assert obs.data == %{"cpu" => 42.0}
      assert obs.severity == :info
    end

    test "returns {:ok, observation, intent} when intent is generated" do
      {pid, sprite_id} = start_sprite()

      assert {:ok, %Observation{} = obs, %Intent{} = intent} =
               Sprite.emit_observation(pid,
                 type: :anomaly,
                 data: %{"message" => "disk full"},
                 severity: :critical
               )

      assert obs.sprite_id == sprite_id
      assert obs.type == :anomaly
      assert intent.kind == :maintenance
      assert intent.source == %{type: :sprite, id: sprite_id}
      assert intent.metadata["observation_id"] == obs.id
    end

    test "returns {:error, reason} for invalid observation type" do
      {pid, _id} = start_sprite()

      assert {:error, {:invalid_type, :bogus}} =
               Sprite.emit_observation(pid, type: :bogus)
    end

    test "returns {:error, reason} for invalid severity" do
      {pid, _id} = start_sprite()

      assert {:error, {:invalid_severity, :bogus}} =
               Sprite.emit_observation(pid, type: :metric, severity: :bogus)
    end

    test "uses sprite_id from GenServer state" do
      specific_id = "sprite-specific-#{System.unique_integer([:positive])}"
      {pid, _id} = start_sprite(sprite_id: specific_id)

      assert {:ok, obs} = Sprite.emit_observation(pid, type: :status)
      assert obs.sprite_id == specific_id
    end
  end

  # ── PubSub Broadcasting ────────────────────────────────────────

  describe "observation PubSub broadcasting" do
    test "broadcasts to per-sprite observation topic" do
      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_observations(sprite_id)

      {:ok, _obs} = Sprite.emit_observation(pid, type: :metric, data: %{"cpu" => 55.0})

      assert_receive %Observation{
                       sprite_id: ^sprite_id,
                       type: :metric,
                       data: %{"cpu" => 55.0}
                     },
                     1_000
    end

    test "broadcasts to all-observations topic" do
      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_all_observations()

      {:ok, _obs} = Sprite.emit_observation(pid, type: :anomaly, severity: :low)

      assert_receive %Observation{
                       sprite_id: ^sprite_id,
                       type: :anomaly,
                       severity: :low
                     },
                     1_000
    end

    test "does not broadcast on invalid observation" do
      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_observations(sprite_id)
      :ok = Events.subscribe_all_observations()

      {:error, _} = Sprite.emit_observation(pid, type: :invalid_type)

      refute_receive %Observation{}, 100
    end
  end

  # ── Telemetry Events ───────────────────────────────────────────

  describe "observation telemetry" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler_id = "sprite-obs-test-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:lattice, :observation, :emitted],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, ref, event_name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{ref: ref}
    end

    test "emits [:lattice, :observation, :emitted] telemetry event", %{ref: ref} do
      {pid, sprite_id} = start_sprite()

      {:ok, _obs} =
        Sprite.emit_observation(pid, type: :status, data: %{"status" => "healthy"})

      assert_receive {:telemetry, ^ref, [:lattice, :observation, :emitted], measurements,
                      metadata},
                     1_000

      assert %{system_time: _} = measurements
      assert metadata.sprite_id == sprite_id
      assert %Observation{} = metadata.observation
      assert metadata.observation.type == :status
    end

    test "does not emit telemetry on invalid observation", %{ref: ref} do
      {pid, _id} = start_sprite()

      {:error, _} = Sprite.emit_observation(pid, type: :bogus)

      refute_receive {:telemetry, ^ref, [:lattice, :observation, :emitted], _, _}, 100
    end
  end

  # ── Intent Generation ──────────────────────────────────────────

  describe "observation-to-intent generation" do
    test "anomaly with high severity generates maintenance intent" do
      {pid, sprite_id} = start_sprite()

      assert {:ok, obs, intent} =
               Sprite.emit_observation(pid,
                 type: :anomaly,
                 data: %{"message" => "tests failing"},
                 severity: :high
               )

      assert intent.kind == :maintenance
      assert intent.source == %{type: :sprite, id: sprite_id}
      assert intent.metadata["observation_id"] == obs.id
    end

    test "anomaly with critical severity generates maintenance intent" do
      {pid, _id} = start_sprite()

      assert {:ok, _obs, %Intent{kind: :maintenance}} =
               Sprite.emit_observation(pid,
                 type: :anomaly,
                 severity: :critical
               )
    end

    test "recommendation with medium severity generates maintenance intent" do
      {pid, _id} = start_sprite()

      assert {:ok, _obs, %Intent{kind: :maintenance}} =
               Sprite.emit_observation(pid,
                 type: :recommendation,
                 data: %{"message" => "update dependency"},
                 severity: :medium
               )
    end

    test "metric observation does not generate intent" do
      {pid, _id} = start_sprite()

      result = Sprite.emit_observation(pid, type: :metric, data: %{"cpu" => 42.0})
      assert {:ok, %Observation{}} = result
      # Two-element tuple means no intent
      assert tuple_size(result) == 2
    end

    test "low severity anomaly does not generate intent" do
      {pid, _id} = start_sprite()

      result = Sprite.emit_observation(pid, type: :anomaly, severity: :low)
      assert {:ok, %Observation{}} = result
      assert tuple_size(result) == 2
    end

    test "status observation does not generate intent" do
      {pid, _id} = start_sprite()

      result = Sprite.emit_observation(pid, type: :status, severity: :critical)
      assert {:ok, %Observation{}} = result
      assert tuple_size(result) == 2
    end
  end
end
