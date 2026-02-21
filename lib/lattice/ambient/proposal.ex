defmodule Lattice.Ambient.Proposal do
  @moduledoc """
  Structured representation of a sprite's handoff proposal.

  When a sprite finishes implementing changes, it produces a `proposal.json`
  file containing metadata about the work: branch name, bundle path, PR details,
  commands run, and safety flags. This module parses and validates that JSON
  into a struct that Lattice uses to push branches and create PRs.
  """

  @protocol_version "bundle-v1"

  @type t :: %__MODULE__{
          protocol_version: String.t(),
          status: String.t(),
          repo: String.t() | nil,
          base_branch: String.t(),
          work_branch: String.t(),
          bundle_path: String.t(),
          patch_path: String.t() | nil,
          summary: String.t() | nil,
          blocked_reason: String.t() | nil,
          pr: map(),
          commands: [map()],
          flags: map()
        }

  defstruct [
    :protocol_version,
    :status,
    :repo,
    :base_branch,
    :work_branch,
    :bundle_path,
    :patch_path,
    :summary,
    :blocked_reason,
    pr: %{},
    commands: [],
    flags: %{}
  ]

  @required_fields ~w(protocol_version status base_branch work_branch bundle_path)

  @doc """
  Parse a JSON string into a `%Proposal{}`.

  Returns `{:ok, proposal}` on success, `{:error, reason}` on failure.
  Validates that `protocol_version` is `"bundle-v1"` and all required fields
  are present.
  """
  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(json) when is_binary(json) do
    with {:ok, data} <- decode_json(json),
         :ok <- validate_required(data),
         :ok <- validate_protocol_version(data) do
      {:ok, to_struct(data)}
    end
  end

  def from_json(_), do: {:error, :invalid_input}

  @doc """
  Returns `true` if the proposal status is `"ready"`.
  """
  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{status: "ready"}), do: true
  def ready?(%__MODULE__{}), do: false

  # ── Private ──────────────────────────────────────────────────────

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _} -> {:error, :invalid_json_structure}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp validate_required(data) do
    missing = Enum.filter(@required_fields, &(not Map.has_key?(data, &1)))

    case missing do
      [] -> :ok
      fields -> {:error, {:missing_fields, fields}}
    end
  end

  defp validate_protocol_version(%{"protocol_version" => @protocol_version}), do: :ok
  defp validate_protocol_version(%{"protocol_version" => v}), do: {:error, {:unknown_protocol, v}}

  defp to_struct(data) do
    %__MODULE__{
      protocol_version: data["protocol_version"],
      status: data["status"],
      repo: data["repo"],
      base_branch: data["base_branch"],
      work_branch: data["work_branch"],
      bundle_path: data["bundle_path"],
      patch_path: data["patch_path"],
      summary: data["summary"],
      blocked_reason: data["blocked_reason"],
      pr: data["pr"] || %{},
      commands: data["commands"] || [],
      flags: data["flags"] || %{}
    }
  end
end
