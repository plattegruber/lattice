defmodule Lattice.Capabilities.GitHub.Labels do
  @moduledoc """
  Label state machine for GitHub issue-based approval workflows.

  Defines the valid labels and their allowed transitions. Each label represents
  a stage in the human-in-the-loop approval lifecycle:

  - `proposed` -- a Sprite has proposed work; awaiting human review
  - `approved` -- a human has approved the proposed work
  - `in-progress` -- the Sprite is actively executing the approved work
  - `blocked` -- work is paused due to an issue (can return to `proposed` or `approved`)
  - `done` -- work is complete (terminal state)

  ## State Machine

  ```
  proposed --> approved --> in-progress --> done
      ^           |              |
      |           v              v
      +------- blocked <--------+
  ```

  Transition validation enforces this flow. Any attempt to transition outside
  the allowed paths returns `{:error, {:invalid_transition, from, to}}`.
  """

  @labels ~w(proposed approved in-progress blocked done)

  @transitions %{
    "proposed" => ~w(approved blocked),
    "approved" => ~w(in-progress blocked),
    "in-progress" => ~w(done blocked),
    "blocked" => ~w(proposed approved),
    "done" => []
  }

  @doc """
  Returns all valid HITL labels.

  ## Examples

      iex> Lattice.Capabilities.GitHub.Labels.all()
      ["proposed", "approved", "in-progress", "blocked", "done"]

  """
  @spec all() :: [String.t()]
  def all, do: @labels

  @doc """
  Returns `true` if the given string is a valid HITL label.

  ## Examples

      iex> Lattice.Capabilities.GitHub.Labels.valid?("proposed")
      true

      iex> Lattice.Capabilities.GitHub.Labels.valid?("invalid")
      false

  """
  @spec valid?(String.t()) :: boolean()
  def valid?(label) when is_binary(label), do: label in @labels

  @doc """
  Returns the list of labels that can be transitioned to from the given label.

  Returns `{:error, :unknown_label}` if the label is not recognized.

  ## Examples

      iex> Lattice.Capabilities.GitHub.Labels.valid_transitions("proposed")
      {:ok, ["approved", "blocked"]}

      iex> Lattice.Capabilities.GitHub.Labels.valid_transitions("done")
      {:ok, []}

      iex> Lattice.Capabilities.GitHub.Labels.valid_transitions("invalid")
      {:error, :unknown_label}

  """
  @spec valid_transitions(String.t()) :: {:ok, [String.t()]} | {:error, :unknown_label}
  def valid_transitions(from) when is_binary(from) do
    case Map.get(@transitions, from) do
      nil -> {:error, :unknown_label}
      targets -> {:ok, targets}
    end
  end

  @doc """
  Validate a label transition from one state to another.

  Returns `:ok` if the transition is valid, or
  `{:error, {:invalid_transition, from, to}}` if not.

  ## Examples

      iex> Lattice.Capabilities.GitHub.Labels.validate_transition("proposed", "approved")
      :ok

      iex> Lattice.Capabilities.GitHub.Labels.validate_transition("proposed", "done")
      {:error, {:invalid_transition, "proposed", "done"}}

      iex> Lattice.Capabilities.GitHub.Labels.validate_transition("invalid", "approved")
      {:error, {:invalid_transition, "invalid", "approved"}}

  """
  @spec validate_transition(String.t(), String.t()) ::
          :ok | {:error, {:invalid_transition, String.t(), String.t()}}
  def validate_transition(from, to) when is_binary(from) and is_binary(to) do
    case Map.get(@transitions, from) do
      nil ->
        {:error, {:invalid_transition, from, to}}

      targets ->
        if to in targets do
          :ok
        else
          {:error, {:invalid_transition, from, to}}
        end
    end
  end

  @doc """
  Returns `true` if the label represents a terminal state.

  ## Examples

      iex> Lattice.Capabilities.GitHub.Labels.terminal?("done")
      true

      iex> Lattice.Capabilities.GitHub.Labels.terminal?("proposed")
      false

  """
  @spec terminal?(String.t()) :: boolean()
  def terminal?("done"), do: true
  def terminal?(_label), do: false

  @doc """
  Returns the initial label for a new work proposal.

  ## Examples

      iex> Lattice.Capabilities.GitHub.Labels.initial()
      "proposed"

  """
  @spec initial() :: String.t()
  def initial, do: "proposed"
end
