defmodule Lattice.Capabilities.Sprites.Stub do
  @moduledoc """
  Stub implementation of the Sprites capability.

  Returns canned responses for development and testing. This module simulates
  a fleet of Sprites with predictable data so the dashboard and process model
  can be built before the real Sprites API integration.
  """

  @behaviour Lattice.Capabilities.Sprites

  @stub_sprites [
    %{
      id: "sprite-001",
      name: "atlas",
      status: "running",
      task: "Implementing user authentication",
      repo: "plattegruber/webapp",
      started_at: "2026-02-16T08:00:00Z"
    },
    %{
      id: "sprite-002",
      name: "beacon",
      status: "sleeping",
      task: nil,
      repo: "plattegruber/api",
      started_at: nil
    },
    %{
      id: "sprite-003",
      name: "cipher",
      status: "running",
      task: "Writing test suite for payments module",
      repo: "plattegruber/payments",
      started_at: "2026-02-16T09:30:00Z"
    }
  ]

  @impl true
  def create_sprite(name, _opts \\ []) do
    {:ok,
     %{
       id: name,
       name: name,
       status: "running",
       task: nil,
       repo: nil,
       started_at: DateTime.to_iso8601(DateTime.utc_now())
     }}
  end

  @impl true
  def list_sprites do
    {:ok, @stub_sprites}
  end

  @impl true
  def get_sprite(id) do
    case Enum.find(@stub_sprites, &(&1.id == id)) do
      nil -> {:error, :not_found}
      sprite -> {:ok, sprite}
    end
  end

  @impl true
  def wake(id) do
    case Enum.find(@stub_sprites, &(&1.id == id)) do
      nil ->
        {:error, :not_found}

      sprite ->
        {:ok, %{sprite | status: "running", started_at: DateTime.to_iso8601(DateTime.utc_now())}}
    end
  end

  @impl true
  def sleep(id) do
    case Enum.find(@stub_sprites, &(&1.id == id)) do
      nil ->
        {:error, :not_found}

      sprite ->
        {:ok, %{sprite | status: "sleeping", task: nil, started_at: nil}}
    end
  end

  @impl true
  def exec(id, command) do
    case Enum.find(@stub_sprites, &(&1.id == id)) do
      nil ->
        {:error, :not_found}

      _sprite ->
        {:ok,
         %{sprite_id: id, command: command, output: "stub output for: #{command}", exit_code: 0}}
    end
  end

  @impl true
  def fetch_logs(id, _opts) do
    case Enum.find(@stub_sprites, &(&1.id == id)) do
      nil ->
        {:error, :not_found}

      _sprite ->
        {:ok,
         [
           "[2026-02-16T08:00:01Z] Sprite #{id} started",
           "[2026-02-16T08:00:02Z] Reading task assignment...",
           "[2026-02-16T08:00:03Z] Working on task..."
         ]}
    end
  end
end
