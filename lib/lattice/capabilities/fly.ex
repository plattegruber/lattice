defmodule Lattice.Capabilities.Fly do
  @moduledoc """
  Behaviour for interacting with the Fly.io Machines API.

  This capability manages deployment and monitoring of Fly Machines.

  All callbacks return tagged tuples (`{:ok, result}` / `{:error, reason}`).
  """

  @typedoc "A Fly Machine ID."
  @type machine_id :: String.t()

  @typedoc "Deployment configuration."
  @type deploy_config :: map()

  @typedoc "A map representing machine status."
  @type machine_status :: map()

  @typedoc "Options for fetching logs."
  @type log_opts :: keyword()

  @doc "Deploy an application or machine with the given configuration."
  @callback deploy(deploy_config()) :: {:ok, map()} | {:error, term()}

  @doc "Fetch logs for a Fly Machine."
  @callback logs(machine_id(), log_opts()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "Get the status of a Fly Machine."
  @callback machine_status(machine_id()) :: {:ok, machine_status()} | {:error, term()}

  @doc "Deploy an application or machine with the given configuration."
  def deploy(config), do: impl().deploy(config)

  @doc "Fetch logs for a Fly Machine."
  def logs(machine_id, opts \\ []), do: impl().logs(machine_id, opts)

  @doc "Get the status of a Fly Machine."
  def machine_status(machine_id), do: impl().machine_status(machine_id)

  defp impl, do: Application.get_env(:lattice, :capabilities)[:fly]
end
