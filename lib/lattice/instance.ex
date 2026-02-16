defmodule Lattice.Instance do
  @moduledoc """
  Instance identity and resource binding for a Lattice deployment.

  Each Lattice instance has a name, an environment, and a set of bound
  resources (GitHub repo, Fly org/app, Sprites API base URL). This module
  provides a clean API for reading that configuration, validating it at
  startup, and logging the boot identity.

  ## Configuration

  Instance config is set in `config/runtime.exs`:

      config :lattice, :instance,
        name: System.get_env("LATTICE_INSTANCE_NAME", "lattice-dev"),
        environment: config_env()

      config :lattice, :resources,
        github_repo: System.get_env("GITHUB_REPO"),
        fly_org: System.get_env("FLY_ORG"),
        fly_app: System.get_env("FLY_APP"),
        sprites_api_base: System.get_env("SPRITES_API_BASE")

  ## Startup Validation

  In production, all resource bindings must be present. Call `validate!/0`
  from `Application.start/2` to fail fast if required bindings are missing.
  In dev and test, missing bindings are tolerated.

  ## Cross-Wiring Guard

  Capability modules can call `validate_resource!/2` to verify they are
  operating against the configured resource, preventing accidental
  cross-environment operations.
  """

  require Logger

  @resource_keys [:github_repo, :fly_org, :fly_app, :sprites_api_base]

  # Keys whose values should be partially redacted in logs
  @secret_patterns ~w(api_base)

  # ── Public API ────────────────────────────────────────────────────

  @doc """
  Returns the instance name.

  ## Examples

      iex> Lattice.Instance.name()
      "lattice-dev"

  """
  @spec name() :: String.t()
  def name do
    instance_config()[:name] || "unknown"
  end

  @doc """
  Returns the instance environment as an atom.

  ## Examples

      iex> Lattice.Instance.environment()
      :dev

  """
  @spec environment() :: atom()
  def environment do
    instance_config()[:environment] || :unknown
  end

  @doc """
  Returns the full resource binding as a keyword list.

  ## Examples

      Lattice.Instance.resources()
      #=> [github_repo: "plattegruber/lattice", fly_org: "lattice-org", ...]

  """
  @spec resources() :: keyword()
  def resources do
    Application.get_env(:lattice, :resources, [])
  end

  @doc """
  Returns a specific bound resource value.

  ## Examples

      Lattice.Instance.resource(:github_repo)
      #=> "plattegruber/lattice"

  """
  @spec resource(atom()) :: String.t() | nil
  def resource(key) when is_atom(key) do
    resources()[key]
  end

  @doc """
  Returns a map suitable for JSON serialization containing instance identity.

  Includes the instance name, environment, and a sanitized view of bound
  resources (secrets are partially redacted).

  ## Examples

      Lattice.Instance.identity()
      #=> %{name: "lattice-dev", environment: :dev, resources: %{github_repo: "plattegruber/lattice", ...}}

  """
  @spec identity() :: map()
  def identity do
    %{
      name: name(),
      environment: environment(),
      resources: sanitized_resources()
    }
  end

  @doc """
  Returns the resource bindings with sensitive values partially redacted.

  Values containing URL-like strings or API endpoints are truncated to show
  only the host portion. Other values are shown in full.
  """
  @spec sanitized_resources() :: map()
  def sanitized_resources do
    resources()
    |> Enum.map(fn {key, value} -> {key, sanitize_value(key, value)} end)
    |> Map.new()
  end

  # ── Validation ────────────────────────────────────────────────────

  @doc """
  Validate that all required resource bindings are present.

  In production, raises if any required binding is missing or blank.
  In dev/test, logs warnings for missing bindings but does not raise.

  Returns `:ok` on success.
  """
  @spec validate!() :: :ok
  def validate! do
    missing = missing_resources()

    case {environment(), missing} do
      {_, []} ->
        :ok

      {:prod, missing_keys} ->
        raise """
        Missing required resource bindings for production: #{inspect(missing_keys)}.

        Set the following environment variables:
        #{Enum.map_join(missing_keys, "\n", &"  - #{env_var_for(&1)}")}
        """

      {env, missing_keys} ->
        Logger.warning(
          "Missing resource bindings in #{env}: #{inspect(missing_keys)}. " <>
            "This is acceptable for development but would fail in production."
        )

        :ok
    end
  end

  @doc """
  Validate that the given resource matches the configured binding.

  Used by capability modules to guard against cross-wiring. Raises
  `ArgumentError` if the actual resource does not match the configured one.

  ## Examples

      Lattice.Instance.validate_resource!(:github_repo, "plattegruber/lattice")
      #=> :ok

      Lattice.Instance.validate_resource!(:github_repo, "other-org/other-repo")
      #=> ** (ArgumentError) ...

  """
  @spec validate_resource!(atom(), String.t()) :: :ok
  def validate_resource!(key, actual) when is_atom(key) and is_binary(actual) do
    case resource(key) do
      nil ->
        Logger.warning("No configured binding for #{key}, skipping cross-wire check")
        :ok

      ^actual ->
        :ok

      expected ->
        raise ArgumentError,
              "Resource cross-wiring detected! " <>
                "Expected #{key} to be #{inspect(expected)}, " <>
                "but got #{inspect(actual)}. " <>
                "Check your environment configuration."
    end
  end

  # ── Boot Logging ──────────────────────────────────────────────────

  @doc """
  Log the full instance identity at boot time.

  Called from `Application.start/2` to make the instance identity visible
  in the boot log. Secrets are sanitized.
  """
  @spec log_boot_info() :: :ok
  def log_boot_info do
    sanitized = sanitized_resources()

    Logger.info("Lattice instance starting",
      instance_name: name(),
      environment: environment(),
      github_repo: sanitized[:github_repo],
      fly_org: sanitized[:fly_org],
      fly_app: sanitized[:fly_app],
      sprites_api_base: sanitized[:sprites_api_base]
    )

    :ok
  end

  # ── Private ───────────────────────────────────────────────────────

  defp instance_config do
    Application.get_env(:lattice, :instance, [])
  end

  defp missing_resources do
    @resource_keys
    |> Enum.filter(fn key ->
      value = resource(key)
      is_nil(value) or value == ""
    end)
  end

  defp env_var_for(:github_repo), do: "GITHUB_REPO"
  defp env_var_for(:fly_org), do: "FLY_ORG"
  defp env_var_for(:fly_app), do: "FLY_APP"
  defp env_var_for(:sprites_api_base), do: "SPRITES_API_BASE"

  defp sanitize_value(_key, nil), do: nil
  defp sanitize_value(_key, ""), do: ""

  defp sanitize_value(key, value) when is_binary(value) do
    if secret_key?(key) do
      redact_url(value)
    else
      value
    end
  end

  defp secret_key?(key) do
    key_string = to_string(key)
    Enum.any?(@secret_patterns, &String.contains?(key_string, &1))
  end

  defp redact_url(value) do
    uri = URI.parse(value)

    if uri.scheme && uri.host do
      "#{uri.scheme}://#{uri.host}/***"
    else
      value
    end
  end
end
