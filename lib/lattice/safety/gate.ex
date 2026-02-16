defmodule Lattice.Safety.Gate do
  @moduledoc """
  Decides whether a classified action is allowed to execute.

  The Gate is a pure functional module (no GenServer) that reads guardrails
  configuration and returns `:allow` or `{:deny, reason}` for a given action.

  ## Decision Logic

  | Classification | Config Required           | Approval Required           |
  |----------------|---------------------------|-----------------------------|
  | `:safe`        | none                      | none                        |
  | `:controlled`  | `allow_controlled: true`  | if `require_approval_for_controlled: true` |
  | `:dangerous`   | `allow_dangerous: true`   | always                      |

  ## Configuration

      config :lattice, :guardrails,
        allow_controlled: true,
        allow_dangerous: false,
        require_approval_for_controlled: true

  ## Usage

      {:ok, action} = Lattice.Safety.Classifier.classify(:sprites, :wake)
      case Lattice.Safety.Gate.check(action) do
        :allow -> # execute the action
        {:deny, :action_not_permitted} -> # action category is disabled
        {:deny, :approval_required} -> # needs human approval first
      end
  """

  alias Lattice.Safety.Action

  @type check_result :: :allow | {:deny, :action_not_permitted | :approval_required}

  @doc """
  Check whether an action is allowed to execute under the current guardrails
  configuration.

  Returns `:allow` if the action can proceed immediately, or `{:deny, reason}`
  if it is blocked.

  ## Examples

      iex> {:ok, action} = Lattice.Safety.Action.new(:sprites, :list_sprites, :safe)
      iex> Lattice.Safety.Gate.check(action)
      :allow

  """
  @spec check(Action.t()) :: check_result()
  def check(%Action{classification: :safe}), do: :allow

  def check(%Action{classification: :controlled}) do
    config = guardrails_config()

    cond do
      not Keyword.get(config, :allow_controlled, true) ->
        {:deny, :action_not_permitted}

      Keyword.get(config, :require_approval_for_controlled, true) ->
        {:deny, :approval_required}

      true ->
        :allow
    end
  end

  def check(%Action{classification: :dangerous}) do
    config = guardrails_config()

    if Keyword.get(config, :allow_dangerous, false) do
      {:deny, :approval_required}
    else
      {:deny, :action_not_permitted}
    end
  end

  @doc """
  Check whether an action is allowed, given an explicit approval status.

  When `approved: true` is passed, the Gate will clear the `:approval_required`
  denial for controlled and dangerous actions (provided the action category is
  enabled in config).

  Returns `:allow` or `{:deny, reason}`.

  ## Examples

      iex> {:ok, action} = Lattice.Safety.Action.new(:sprites, :wake, :controlled)
      iex> Lattice.Safety.Gate.check_with_approval(action, approved: true)
      :allow

  """
  @spec check_with_approval(Action.t(), keyword()) :: check_result()
  def check_with_approval(%Action{} = action, opts) do
    case check(action) do
      :allow ->
        :allow

      {:deny, :approval_required} ->
        if Keyword.get(opts, :approved, false), do: :allow, else: {:deny, :approval_required}

      {:deny, reason} ->
        {:deny, reason}
    end
  end

  @doc """
  Returns `true` if the action would require approval (but is otherwise allowed).

  Useful for pre-flight checks before creating a GitHub approval issue.

  ## Examples

      iex> {:ok, action} = Lattice.Safety.Action.new(:sprites, :wake, :controlled)
      iex> Lattice.Safety.Gate.requires_approval?(action)
      true

      iex> {:ok, action} = Lattice.Safety.Action.new(:sprites, :list_sprites, :safe)
      iex> Lattice.Safety.Gate.requires_approval?(action)
      false

  """
  @spec requires_approval?(Action.t()) :: boolean()
  def requires_approval?(%Action{} = action) do
    check(action) == {:deny, :approval_required}
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp guardrails_config do
    Application.get_env(:lattice, :guardrails, [])
  end
end
