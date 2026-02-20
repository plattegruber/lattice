defmodule Lattice.Health.DetectorTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Events
  alias Lattice.Health.Detector
  alias Lattice.Intents.Observation
  alias Lattice.Intents.Store

  setup do
    # The Detector is started by application.ex; clear its history
    Detector.clear_history()
    :ok
  end

  defp make_observation(opts) do
    sprite_id = Keyword.get(opts, :sprite_id, "sprite-health-test")
    type = Keyword.get(opts, :type, :anomaly)
    severity = Keyword.get(opts, :severity, :critical)
    data = Keyword.get(opts, :data, %{"message" => "test health issue"})

    {:ok, obs} = Observation.new(sprite_id, type, severity: severity, data: data)
    obs
  end

  describe "severity gating" do
    test "creates intent for critical observations" do
      obs = make_observation(severity: :critical)
      Events.broadcast_observation(obs)
      Process.sleep(50)

      intents = elem(Store.list(), 1)
      health_intents = Enum.filter(intents, &(&1.kind == :health_detect))
      assert health_intents != []

      intent = List.last(health_intents)
      assert intent.state == :approved
      assert intent.payload["severity"] == "critical"
      assert intent.payload["sprite_id"] == "sprite-health-test"
    end

    test "creates intent for high observations" do
      obs = make_observation(severity: :high)
      Events.broadcast_observation(obs)
      Process.sleep(50)

      intents = elem(Store.list(), 1)
      health_intents = Enum.filter(intents, &(&1.kind == :health_detect))
      assert health_intents != []

      intent = List.last(health_intents)
      assert intent.state == :proposed
      assert intent.payload["severity"] == "high"
    end

    test "does not create intent for medium observations" do
      before_count =
        elem(Store.list(), 1) |> Enum.count(&(&1.kind == :health_detect))

      obs = make_observation(severity: :medium)
      Events.broadcast_observation(obs)
      Process.sleep(50)

      after_count =
        elem(Store.list(), 1) |> Enum.count(&(&1.kind == :health_detect))

      assert after_count == before_count
    end

    test "does not create intent for low observations" do
      before_count =
        elem(Store.list(), 1) |> Enum.count(&(&1.kind == :health_detect))

      obs = make_observation(severity: :low)
      Events.broadcast_observation(obs)
      Process.sleep(50)

      after_count =
        elem(Store.list(), 1) |> Enum.count(&(&1.kind == :health_detect))

      assert after_count == before_count
    end

    test "does not create intent for info observations" do
      before_count =
        elem(Store.list(), 1) |> Enum.count(&(&1.kind == :health_detect))

      obs = make_observation(severity: :info)
      Events.broadcast_observation(obs)
      Process.sleep(50)

      after_count =
        elem(Store.list(), 1) |> Enum.count(&(&1.kind == :health_detect))

      assert after_count == before_count
    end
  end

  describe "deduplication" do
    test "deduplicates observations within cooldown window" do
      obs1 = make_observation(severity: :critical, sprite_id: "sprite-dedup")
      obs2 = make_observation(severity: :critical, sprite_id: "sprite-dedup")

      Events.broadcast_observation(obs1)
      Process.sleep(50)
      Events.broadcast_observation(obs2)
      Process.sleep(50)

      intents =
        elem(Store.list(), 1)
        |> Enum.filter(fn i ->
          i.kind == :health_detect and i.payload["sprite_id"] == "sprite-dedup"
        end)

      assert [_] = intents
    end

    test "allows observations from different sprites" do
      obs1 = make_observation(severity: :critical, sprite_id: "sprite-a")
      obs2 = make_observation(severity: :critical, sprite_id: "sprite-b")

      Events.broadcast_observation(obs1)
      Process.sleep(50)
      Events.broadcast_observation(obs2)
      Process.sleep(50)

      a_intents =
        elem(Store.list(), 1)
        |> Enum.filter(fn i ->
          i.kind == :health_detect and i.payload["sprite_id"] == "sprite-a"
        end)

      b_intents =
        elem(Store.list(), 1)
        |> Enum.filter(fn i ->
          i.kind == :health_detect and i.payload["sprite_id"] == "sprite-b"
        end)

      assert a_intents != []
      assert b_intents != []
    end
  end

  describe "intent content" do
    test "includes observation data in payload" do
      data = %{"message" => "High CPU usage", "cpu" => 95.2}
      obs = make_observation(severity: :critical, data: data)
      Events.broadcast_observation(obs)
      Process.sleep(50)

      intent =
        elem(Store.list(), 1)
        |> Enum.filter(&(&1.kind == :health_detect))
        |> List.last()

      assert intent.payload["observation_data"]["cpu"] == 95.2
      assert intent.payload["observation_id"] == obs.id
      assert intent.summary == "High CPU usage"
    end

    test "uses fallback summary when no message in data" do
      obs = make_observation(severity: :critical, data: %{"cpu" => 99.0})
      Events.broadcast_observation(obs)
      Process.sleep(50)

      intent =
        elem(Store.list(), 1)
        |> Enum.filter(&(&1.kind == :health_detect))
        |> List.last()

      assert intent.summary =~ "Health issue detected"
    end
  end

  describe "detection_history/0" do
    test "returns detection history" do
      obs = make_observation(severity: :critical, sprite_id: "sprite-hist")
      Events.broadcast_observation(obs)
      Process.sleep(50)

      history = Detector.detection_history()
      assert map_size(history) >= 1
    end

    test "clear_history/0 resets history" do
      obs = make_observation(severity: :critical, sprite_id: "sprite-clear")
      Events.broadcast_observation(obs)
      Process.sleep(50)

      Detector.clear_history()
      assert Detector.detection_history() == %{}
    end
  end
end
