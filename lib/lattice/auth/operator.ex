defmodule Lattice.Auth.Operator do
  @moduledoc """
  Represents an authenticated human operator.

  Every request (API or LiveView) carries an Operator struct that identifies
  who is performing the action. This identity flows through to audit logs,
  telemetry metadata, and safety gating decisions.

  ## Roles

  - `:viewer` -- read-only access, can observe but not trigger actions
  - `:operator` -- can trigger actions (wake/sleep sprites, approve, etc.)
  - `:admin` -- full access, including configuration changes

  ## Fields

  - `id` -- unique identifier (Clerk user ID or stub ID)
  - `name` -- display name for logs and dashboard
  - `role` -- one of `:viewer`, `:operator`, `:admin`
  """

  @type role :: :viewer | :operator | :admin

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          role: role()
        }

  @enforce_keys [:id, :name, :role]
  defstruct [:id, :name, :role]

  @valid_roles [:viewer, :operator, :admin]

  @doc """
  Create a new Operator struct.

  Returns `{:ok, operator}` if the role is valid, or
  `{:error, {:invalid_role, role}}` otherwise.

  ## Examples

      iex> Lattice.Auth.Operator.new("user_123", "Ada Lovelace", :operator)
      {:ok, %Lattice.Auth.Operator{id: "user_123", name: "Ada Lovelace", role: :operator}}

      iex> Lattice.Auth.Operator.new("user_123", "Ada", :superadmin)
      {:error, {:invalid_role, :superadmin}}

  """
  @spec new(String.t(), String.t(), role()) :: {:ok, t()} | {:error, term()}
  def new(id, name, role) when role in @valid_roles do
    {:ok, %__MODULE__{id: id, name: name, role: role}}
  end

  def new(_id, _name, role) do
    {:error, {:invalid_role, role}}
  end

  @doc """
  Returns true if the operator has at least the given role level.

  Role hierarchy: `:admin` > `:operator` > `:viewer`.

  ## Examples

      iex> op = %Lattice.Auth.Operator{id: "1", name: "Ada", role: :admin}
      iex> Lattice.Auth.Operator.has_role?(op, :operator)
      true

      iex> op = %Lattice.Auth.Operator{id: "1", name: "Ada", role: :viewer}
      iex> Lattice.Auth.Operator.has_role?(op, :operator)
      false

  """
  @spec has_role?(t(), role()) :: boolean()
  def has_role?(%__MODULE__{role: actual_role}, required_role) do
    role_level(actual_role) >= role_level(required_role)
  end

  @doc "Returns the list of valid roles."
  @spec valid_roles() :: [role()]
  def valid_roles, do: @valid_roles

  # ── Private ──────────────────────────────────────────────────────────

  defp role_level(:viewer), do: 0
  defp role_level(:operator), do: 1
  defp role_level(:admin), do: 2
end
