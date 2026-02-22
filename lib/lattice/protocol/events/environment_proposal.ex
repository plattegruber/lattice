defmodule Lattice.Protocol.Events.EnvironmentProposal do
  @moduledoc """
  Protocol v1 ENVIRONMENT_PROPOSAL event. Sprite proposes an improvement
  to its environment or setup.

  Fire-and-forget — sprites never receive acceptance feedback in the
  same session. Accepted changes apply only to future runs.
  """

  @valid_adjustment_types ~w(
    runtime_install
    runtime_version_adjust
    dependency_manager_switch
    add_preinstall_step
    adjust_smoke_command
    add_system_package
    enable_network_access
    escalate_to_human
  )

  defstruct [:observed_failure, :suggested_adjustment, :confidence, :scope, evidence: []]

  def from_map(map) do
    %__MODULE__{
      observed_failure: Map.get(map, "observed_failure", %{}),
      suggested_adjustment: Map.get(map, "suggested_adjustment", %{}),
      confidence: Map.get(map, "confidence", 0.0),
      evidence: Map.get(map, "evidence", []),
      scope: Map.get(map, "scope")
    }
  end

  def valid_adjustment_types, do: @valid_adjustment_types

  def valid_adjustment_type?(type), do: type in @valid_adjustment_types
end
