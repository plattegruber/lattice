defmodule Lattice.Intents.Governance.Labels do
  @moduledoc """
  Intent governance labels for GitHub issue-based approval workflows.

  Maps intent lifecycle states to GitHub labels. These labels are applied to
  governance issues created when intents require human approval.

  ## Labels

  - `intent-awaiting-approval` — intent is waiting for human review
  - `intent-approved` — human has approved the intent
  - `intent-rejected` — human has rejected the intent
  """

  @awaiting_approval "intent-awaiting-approval"
  @approved "intent-approved"
  @rejected "intent-rejected"

  @all_labels [@awaiting_approval, @approved, @rejected]

  @state_to_label %{
    awaiting_approval: @awaiting_approval,
    approved: @approved,
    rejected: @rejected
  }

  @label_to_state %{
    @approved => :approved,
    @rejected => :rejected
  }

  # ── Public API ────────────────────────────────────────────────────

  @doc "Returns all intent governance labels."
  @spec all() :: [String.t()]
  def all, do: @all_labels

  @doc "Returns the label for the `awaiting_approval` state."
  @spec awaiting_approval() :: String.t()
  def awaiting_approval, do: @awaiting_approval

  @doc "Returns the label for the `approved` state."
  @spec approved() :: String.t()
  def approved, do: @approved

  @doc "Returns the label for the `rejected` state."
  @spec rejected() :: String.t()
  def rejected, do: @rejected

  @doc """
  Returns the GitHub label for a given intent state.

  Returns `{:ok, label}` for states that have a corresponding label, or
  `{:error, :no_label}` for states without governance labels.

  ## Examples

      iex> Lattice.Intents.Governance.Labels.for_state(:awaiting_approval)
      {:ok, "intent-awaiting-approval"}

      iex> Lattice.Intents.Governance.Labels.for_state(:running)
      {:error, :no_label}

  """
  @spec for_state(atom()) :: {:ok, String.t()} | {:error, :no_label}
  def for_state(state) do
    case Map.fetch(@state_to_label, state) do
      {:ok, label} -> {:ok, label}
      :error -> {:error, :no_label}
    end
  end

  @doc """
  Returns the intent state for a given governance label.

  Returns `{:ok, state}` for recognized governance labels, or
  `{:error, :unknown_label}` for unrecognized labels.

  ## Examples

      iex> Lattice.Intents.Governance.Labels.to_state("intent-approved")
      {:ok, :approved}

      iex> Lattice.Intents.Governance.Labels.to_state("some-other-label")
      {:error, :unknown_label}

  """
  @spec to_state(String.t()) :: {:ok, atom()} | {:error, :unknown_label}
  def to_state(label) do
    case Map.fetch(@label_to_state, label) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, :unknown_label}
    end
  end

  @doc """
  Returns `true` if the given label is a recognized intent governance label.

  ## Examples

      iex> Lattice.Intents.Governance.Labels.valid?("intent-approved")
      true

      iex> Lattice.Intents.Governance.Labels.valid?("bug")
      false

  """
  @spec valid?(String.t()) :: boolean()
  def valid?(label) when is_binary(label), do: label in @all_labels
end
