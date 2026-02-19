defmodule LatticeWeb.SpriteLive.ProtocolEventsTest do
  @moduledoc """
  Tests for protocol event (progress, warning, checkpoint) streaming
  to the sprite detail LiveView.
  """

  use LatticeWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest

  alias Lattice.Intents.Store.ETS, as: IntentStore
  alias Lattice.Protocol.Event
  alias Lattice.Protocol.Events.Checkpoint
  alias Lattice.Protocol.Events.Progress
  alias Lattice.Protocol.Events.Warning
  alias Lattice.Sprites.Sprite

  @moduletag :unit

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    IntentStore.reset()

    Lattice.Capabilities.MockSprites
    |> Mox.stub(:fetch_logs, fn _sprite_id, _opts -> {:ok, []} end)

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp start_test_sprite(sprite_id) do
    {:ok, _pid} =
      Sprite.start_link(
        sprite_id: sprite_id,
        reconcile_interval_ms: 60_000,
        name: Sprite.via(sprite_id)
      )
  end

  defp make_progress_event(message, opts \\ []) do
    data = %Progress{
      message: message,
      percent: Keyword.get(opts, :percent),
      phase: Keyword.get(opts, :phase)
    }

    Event.new("progress", data)
  end

  defp make_warning_event(message, opts \\ []) do
    data = %Warning{
      message: message,
      details: Keyword.get(opts, :details)
    }

    Event.new("warning", data)
  end

  defp make_checkpoint_event(message, opts \\ []) do
    data = %Checkpoint{
      message: message,
      metadata: Keyword.get(opts, :metadata, %{})
    }

    Event.new("checkpoint", data)
  end

  defp send_protocol_event(view, event) do
    send(view.pid, {:protocol_event, event})
  end

  # ── Protocol Event Rendering ─────────────────────────────────────────

  describe "progress events" do
    setup do
      sprite_id = "proto-sprite-#{System.unique_integer([:positive])}"
      start_test_sprite(sprite_id)
      %{sprite_id: sprite_id}
    end

    test "renders progress status bar when progress event received",
         %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      event = make_progress_event("Installing dependencies", percent: 45, phase: "setup")
      send_protocol_event(view, event)

      html = render(view)
      assert html =~ "Installing dependencies"
      assert html =~ "progress"
    end

    test "renders progress bar with percent",
         %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      event = make_progress_event("Building", percent: 75, phase: "compile")
      send_protocol_event(view, event)

      html = render(view)
      assert html =~ "Building"
      assert html =~ "value=\"75\""
      assert html =~ "compile"
    end

    test "shows progress in event timeline",
         %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      event = make_progress_event("Running tests")
      send_protocol_event(view, event)

      html = render(view)
      assert html =~ "Running tests"
      assert html =~ "progress"
    end
  end

  describe "warning events" do
    setup do
      sprite_id = "warn-sprite-#{System.unique_integer([:positive])}"
      start_test_sprite(sprite_id)
      %{sprite_id: sprite_id}
    end

    test "shows warning in event timeline",
         %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      event = make_warning_event("Disk space running low")
      send_protocol_event(view, event)

      html = render(view)
      assert html =~ "Disk space running low"
      assert html =~ "warning"
    end
  end

  describe "checkpoint events" do
    setup do
      sprite_id = "ckpt-sprite-#{System.unique_integer([:positive])}"
      start_test_sprite(sprite_id)
      %{sprite_id: sprite_id}
    end

    test "shows checkpoint in event timeline",
         %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      event = make_checkpoint_event("Tests passing")
      send_protocol_event(view, event)

      html = render(view)
      assert html =~ "Tests passing"
      assert html =~ "checkpoint"
    end
  end

  describe "multiple protocol events" do
    setup do
      sprite_id = "multi-sprite-#{System.unique_integer([:positive])}"
      start_test_sprite(sprite_id)
      %{sprite_id: sprite_id}
    end

    test "accumulates multiple protocol events in timeline",
         %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      send_protocol_event(view, make_progress_event("Step 1"))
      send_protocol_event(view, make_warning_event("Watch out"))
      send_protocol_event(view, make_checkpoint_event("Milestone reached"))

      html = render(view)
      assert html =~ "Step 1"
      assert html =~ "Watch out"
      assert html =~ "Milestone reached"
    end

    test "unknown protocol event types are handled gracefully",
         %{conn: conn, sprite_id: sprite_id} do
      {:ok, view, _html} = live(conn, ~p"/sprites/#{sprite_id}")

      # Unknown event type should not crash the LiveView
      unknown_event = Event.new("custom_type", %{message: "custom data"})
      send_protocol_event(view, unknown_event)

      html = render(view)
      assert html =~ sprite_id
    end
  end
end
