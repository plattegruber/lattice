defmodule Lattice.Safety.Audit do
  @moduledoc """
  Audit logging for capability invocations.

  Every capability call flows through Audit, which:

  1. Creates an `AuditEntry` struct capturing the full context
  2. Emits a `[:lattice, :safety, :audit]` Telemetry event
  3. Broadcasts the entry via PubSub on the `"safety:audit"` topic

  This ensures every action — allowed or denied, successful or failed —
  is observable in real time through the event infrastructure and available
  for the Incidents view in the LiveView dashboard.

  ## Argument Sanitization

  Arguments are sanitized before logging to prevent secrets from appearing
  in audit trails. The `sanitize_args/1` function redacts values for keys
  known to contain sensitive data (tokens, passwords, secrets, keys).
  """

  alias Lattice.Safety.AuditEntry

  @sensitive_keys ~w(token password secret key api_key access_token)a

  @doc """
  Log a capability invocation.

  Creates an AuditEntry, emits a Telemetry event, and broadcasts via PubSub.

  ## Parameters

  - `capability` -- capability name (e.g., `:sprites`)
  - `operation` -- function name (e.g., `:wake`)
  - `classification` -- safety classification (`:safe`, `:controlled`, `:dangerous`)
  - `result` -- outcome (`:ok`, `{:error, reason}`, or `:denied`)
  - `actor` -- who initiated (`:system`, `:human`, `:scheduled`)
  - `opts` -- optional keyword list:
    - `:args` -- list of arguments (will be sanitized)
    - `:timestamp` -- override timestamp

  ## Examples

      Lattice.Safety.Audit.log(:sprites, :wake, :controlled, :ok, :human, args: ["sprite-001"])

  """
  @spec log(
          atom(),
          atom(),
          atom(),
          :ok | {:error, term()} | :denied,
          AuditEntry.actor(),
          keyword()
        ) :: :ok
  def log(capability, operation, classification, result, actor, opts \\ []) do
    sanitized_opts = Keyword.update(opts, :args, [], &sanitize_args/1)

    {:ok, entry} =
      AuditEntry.new(capability, operation, classification, result, actor, sanitized_opts)

    emit_telemetry(entry)
    broadcast(entry)

    :ok
  end

  @doc """
  Sanitize a list of arguments by redacting sensitive values.

  Map arguments have their sensitive keys replaced with `"[REDACTED]"`.
  Other argument types are passed through unchanged.

  ## Examples

      iex> Lattice.Safety.Audit.sanitize_args([%{token: "secret123", name: "atlas"}])
      [%{token: "[REDACTED]", name: "atlas"}]

      iex> Lattice.Safety.Audit.sanitize_args(["sprite-001", "echo hello"])
      ["sprite-001", "echo hello"]

  """
  @spec sanitize_args(list()) :: list()
  def sanitize_args(args) when is_list(args) do
    Enum.map(args, &sanitize_arg/1)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp sanitize_arg(arg) when is_map(arg) do
    Map.new(arg, fn {key, value} ->
      if key in @sensitive_keys or
           (is_binary(key) and String.downcase(key) in Enum.map(@sensitive_keys, &to_string/1)) do
        {key, "[REDACTED]"}
      else
        {key, value}
      end
    end)
  end

  defp sanitize_arg(arg), do: arg

  defp emit_telemetry(%AuditEntry{} = entry) do
    :telemetry.execute(
      [:lattice, :safety, :audit],
      %{system_time: System.system_time()},
      %{entry: entry}
    )
  end

  defp broadcast(%AuditEntry{} = entry) do
    Phoenix.PubSub.broadcast(Lattice.PubSub, "safety:audit", entry)
  end
end
