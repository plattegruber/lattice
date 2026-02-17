defmodule Lattice.Intents.Executor.Sprite do
  @moduledoc """
  Executor that routes intents to Sprite processes via capability modules.

  The Sprite executor handles intents that originate from or target a specific
  Sprite. It resolves the capability and operation from the intent payload,
  invokes the capability module's public API, and collects the outcome.

  ## Routing

  The intent payload must contain `"capability"` and `"operation"` fields
  (string keys) that map to a registered capability module and function.

  ## Capability Resolution

  Capabilities are resolved from the application config:

      config :lattice, :capabilities,
        sprites: Lattice.Capabilities.Sprites.Live,
        github: Lattice.Capabilities.GitHub.Live,
        fly: Lattice.Capabilities.Fly.Live
  """

  @behaviour Lattice.Intents.Executor

  alias Lattice.Intents.ExecutionResult
  alias Lattice.Intents.Intent

  @capability_modules %{
    "sprites" => :sprites,
    "github" => :github,
    "fly" => :fly,
    "secret_store" => :secret_store
  }

  # ── Executor Callbacks ─────────────────────────────────────────────

  @impl Lattice.Intents.Executor
  def can_execute?(%Intent{kind: :action, source: %{type: :sprite}} = intent) do
    has_capability?(intent)
  end

  def can_execute?(%Intent{}), do: false

  @impl Lattice.Intents.Executor
  def execute(%Intent{} = intent) do
    started_at = DateTime.utc_now()
    start_mono = System.monotonic_time(:millisecond)

    case invoke_capability(intent) do
      {:ok, output} ->
        duration_ms = System.monotonic_time(:millisecond) - start_mono
        completed_at = DateTime.utc_now()

        ExecutionResult.success(duration_ms, started_at, completed_at,
          output: output,
          executor: __MODULE__
        )

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_mono
        completed_at = DateTime.utc_now()

        ExecutionResult.failure(duration_ms, started_at, completed_at,
          error: reason,
          executor: __MODULE__
        )
    end
  end

  # ── Private ────────────────────────────────────────────────────────

  defp invoke_capability(%Intent{payload: payload}) do
    capability_key = Map.get(payload, "capability", "")
    operation_str = Map.get(payload, "operation", "")
    args = Map.get(payload, "args", [])

    with {:ok, cap_config_key} <- resolve_capability_key(capability_key),
         {:ok, module} <- get_capability_module(cap_config_key),
         {:ok, operation} <- resolve_operation(operation_str),
         :ok <- validate_exported(module, operation, args) do
      apply_capability(module, operation, args)
    end
  end

  defp resolve_capability_key(key) when is_binary(key) do
    case Map.get(@capability_modules, key) do
      nil -> {:error, {:unknown_capability, key}}
      config_key -> {:ok, config_key}
    end
  end

  defp resolve_capability_key(key) when is_atom(key) do
    resolve_capability_key(Atom.to_string(key))
  end

  defp resolve_capability_key(key), do: {:error, {:invalid_capability, key}}

  defp get_capability_module(config_key) do
    case Application.get_env(:lattice, :capabilities, %{})[config_key] do
      nil -> {:error, {:capability_not_configured, config_key}}
      module -> {:ok, module}
    end
  end

  defp resolve_operation(operation) when is_binary(operation) do
    {:ok, String.to_existing_atom(operation)}
  rescue
    ArgumentError -> {:error, {:unknown_operation, operation}}
  end

  defp resolve_operation(operation) when is_atom(operation), do: {:ok, operation}
  defp resolve_operation(operation), do: {:error, {:invalid_operation, operation}}

  defp validate_exported(module, operation, args) do
    arity = length(args)

    if function_exported?(module, operation, arity) do
      :ok
    else
      {:error, {:function_not_exported, {module, operation, arity}}}
    end
  end

  defp apply_capability(module, operation, args) do
    apply(module, operation, args)
  end

  defp has_capability?(%Intent{payload: payload}) do
    Map.has_key?(payload, "capability") and Map.has_key?(payload, "operation")
  end
end
