defmodule Lattice.Safety.AuditEntry do
  @moduledoc """
  Represents a single audit log entry for a capability invocation.

  Every capability call — whether allowed, denied, successful, or failed —
  produces an AuditEntry. These entries are emitted as Telemetry events and
  broadcast via PubSub for real-time visibility in the dashboard.

  ## Fields

  - `capability` -- the capability module name (e.g., `:sprites`, `:github`)
  - `operation` -- the function name (e.g., `:wake`, `:deploy`)
  - `args` -- sanitized arguments (secrets/tokens redacted)
  - `classification` -- safety classification (`:safe`, `:controlled`, `:dangerous`)
  - `result` -- outcome of the invocation (`:ok`, `{:error, reason}`, or `:denied`)
  - `actor` -- who or what initiated the action (`:system`, `:human`, `:scheduled`)
  - `timestamp` -- when the invocation occurred
  """

  @type actor :: :system | :human | :scheduled

  @type t :: %__MODULE__{
          capability: atom(),
          operation: atom(),
          args: list(),
          classification: atom(),
          result: :ok | {:error, term()} | :denied,
          actor: actor(),
          timestamp: DateTime.t()
        }

  @enforce_keys [:capability, :operation, :classification, :result, :actor, :timestamp]
  defstruct [:capability, :operation, :classification, :result, :actor, :timestamp, args: []]

  @valid_actors [:system, :human, :scheduled]

  @doc """
  Creates a new AuditEntry.

  ## Examples

      iex> Lattice.Safety.AuditEntry.new(:sprites, :wake, :controlled, :ok, :human)
      {:ok, %Lattice.Safety.AuditEntry{capability: :sprites, operation: :wake, classification: :controlled, result: :ok, actor: :human, ...}}

  """
  @spec new(atom(), atom(), atom(), :ok | {:error, term()} | :denied, actor(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def new(capability, operation, classification, result, actor, opts \\ [])

  def new(capability, operation, classification, result, actor, opts)
      when actor in @valid_actors do
    {:ok,
     %__MODULE__{
       capability: capability,
       operation: operation,
       args: Keyword.get(opts, :args, []),
       classification: classification,
       result: result,
       actor: actor,
       timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
     }}
  end

  def new(_capability, _operation, _classification, _result, actor, _opts) do
    {:error, {:invalid_actor, actor}}
  end

  @doc "Returns the list of valid actor types."
  @spec valid_actors() :: [actor()]
  def valid_actors, do: @valid_actors
end
