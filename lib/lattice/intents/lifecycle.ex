defmodule Lattice.Intents.Lifecycle do
  @moduledoc """
  State machine for Intent lifecycle transitions.

  Validates and applies state transitions on `%Intent{}` structs, maintaining
  a transition log and lifecycle timestamps.

  ## States

      proposed → classified → awaiting_approval → approved → running → completed
                            ↘ approved ────────────────────────────↗
                                                                    ↘ failed

  Terminal states: `:completed`, `:failed`, `:rejected`, `:canceled`
  """

  alias Lattice.Intents.Intent

  @transitions %{
    proposed: [:classified],
    classified: [:awaiting_approval, :approved],
    awaiting_approval: [:approved, :rejected, :canceled],
    approved: [:running, :canceled],
    running: [:completed, :failed],
    completed: [],
    failed: [],
    rejected: [],
    canceled: []
  }

  @valid_states Map.keys(@transitions)
  @terminal_states for {state, []} <- @transitions, do: state

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Transition an intent to a new state.

  Updates the intent's state, `updated_at`, transition log, and the
  appropriate lifecycle timestamp. Returns `{:ok, intent}` on success.

  ## Options

  - `:actor` — who triggered the transition (default: `nil`)
  - `:reason` — why the transition happened (default: `nil`)
  """
  @spec transition(Intent.t(), Intent.state(), keyword()) ::
          {:ok, Intent.t()} | {:error, term()}
  def transition(%Intent{} = intent, new_state, opts \\ []) do
    with :ok <- validate_state(new_state),
         :ok <- validate_transition(intent.state, new_state) do
      now = DateTime.utc_now()

      entry = %{
        from: intent.state,
        to: new_state,
        timestamp: now,
        actor: Keyword.get(opts, :actor),
        reason: Keyword.get(opts, :reason)
      }

      updated =
        intent
        |> Map.put(:state, new_state)
        |> Map.put(:updated_at, now)
        |> Map.update!(:transition_log, fn log -> [entry | log] end)
        |> put_lifecycle_timestamp(new_state, now)

      {:ok, updated}
    end
  end

  @doc """
  Returns the list of valid target states from the given state.

  Returns an empty list for terminal states or `{:error, {:invalid_state, state}}`
  for unrecognized states.
  """
  @spec valid_transitions(Intent.state()) :: [Intent.state()] | {:error, term()}
  def valid_transitions(state) when is_map_key(@transitions, state) do
    Map.fetch!(@transitions, state)
  end

  def valid_transitions(state), do: {:error, {:invalid_state, state}}

  @doc "Returns `true` if the given state is terminal (no further transitions)."
  @spec terminal?(Intent.state()) :: boolean()
  def terminal?(state) when state in @terminal_states, do: true
  def terminal?(_state), do: false

  @doc "Returns all valid lifecycle states."
  @spec valid_states() :: [Intent.state()]
  def valid_states, do: @valid_states

  # ── Private ──────────────────────────────────────────────────────────

  defp validate_state(state) when state in @valid_states, do: :ok
  defp validate_state(state), do: {:error, {:invalid_state, state}}

  defp validate_transition(from, to) do
    if to in Map.fetch!(@transitions, from) do
      :ok
    else
      {:error, {:invalid_transition, %{from: from, to: to}}}
    end
  end

  defp put_lifecycle_timestamp(intent, :classified, now),
    do: Map.put(intent, :classified_at, now)

  defp put_lifecycle_timestamp(intent, :approved, now),
    do: Map.put(intent, :approved_at, now)

  defp put_lifecycle_timestamp(intent, :running, now),
    do: Map.put(intent, :started_at, now)

  defp put_lifecycle_timestamp(intent, state, now) when state in [:completed, :failed],
    do: Map.put(intent, :completed_at, now)

  defp put_lifecycle_timestamp(intent, _state, _now), do: intent
end
