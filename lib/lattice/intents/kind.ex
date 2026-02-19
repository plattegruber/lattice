defmodule Lattice.Intents.Kind do
  @moduledoc """
  Behaviour and registry for intent kinds.

  Each kind defines its name, description, required payload fields, and
  default safety classification. The registry allows compile-time registration
  and runtime lookup of kinds.

  ## Built-in kinds

  - `:action` — produces side effects (deploy, modify infrastructure)
  - `:inquiry` — requests human input or secrets
  - `:maintenance` — proposes system improvements

  ## Extended kinds

  - `:issue_triage` — parse an issue, propose a plan
  - `:pr_fixup` — respond to PR review feedback
  - `:pr_create` — create a PR from an approved plan

  ## Implementing a kind

      defmodule MyApp.Intents.Kind.Custom do
        @behaviour Lattice.Intents.Kind

        @impl true
        def name, do: :custom

        @impl true
        def description, do: "Custom intent kind"

        @impl true
        def required_payload_fields, do: [:some_field]

        @impl true
        def default_classification, do: :controlled
      end

  Then register it:

      Lattice.Intents.Kind.register(MyApp.Intents.Kind.Custom)
  """

  require Logger

  @type kind_name :: atom()

  @doc "The atom name identifying this kind."
  @callback name() :: kind_name()

  @doc "Human-readable description for dashboard display."
  @callback description() :: String.t()

  @doc "Payload fields required for this kind (advisory, not blocking)."
  @callback required_payload_fields() :: [atom() | String.t()]

  @doc "Default safety classification when the classifier has no specific mapping."
  @callback default_classification() :: :safe | :controlled | :dangerous

  # ── Registry (ETS-backed) ─────────────────────────────────────────

  @table_name :lattice_intent_kinds

  @doc """
  Initialize the kind registry. Called during application startup.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, [:set, :public, :named_table])
    end

    register_builtins()
    :ok
  end

  @doc """
  Register a kind module in the registry.
  """
  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    ensure_table()
    name = module.name()
    :ets.insert(@table_name, {name, module})
    :ok
  end

  @doc """
  Look up a kind module by name.
  """
  @spec lookup(kind_name()) :: {:ok, module()} | {:error, :unknown_kind}
  def lookup(name) when is_atom(name) do
    ensure_table()

    case :ets.lookup(@table_name, name) do
      [{^name, module}] -> {:ok, module}
      [] -> {:error, :unknown_kind}
    end
  end

  @doc """
  List all registered kind names.
  """
  @spec registered() :: [kind_name()]
  def registered do
    ensure_table()

    :ets.foldl(fn {name, _module}, acc -> [name | acc] end, [], @table_name)
    |> Enum.sort()
  end

  @doc """
  List all registered kind modules with metadata.
  """
  @spec all() :: [%{name: kind_name(), description: String.t(), module: module()}]
  def all do
    ensure_table()

    :ets.foldl(
      fn {name, module}, acc ->
        [%{name: name, description: module.description(), module: module} | acc]
      end,
      [],
      @table_name
    )
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Validate a payload against a kind's required fields.

  Returns `:ok` or `{:warn, missing_fields}`. Advisory only — does not reject.
  """
  @spec validate_payload(kind_name(), map()) :: :ok | {:warn, [atom() | String.t()]}
  def validate_payload(kind_name, payload) when is_atom(kind_name) and is_map(payload) do
    case lookup(kind_name) do
      {:ok, module} ->
        required = module.required_payload_fields()

        missing =
          Enum.reject(required, fn field ->
            key = to_string(field)
            Map.has_key?(payload, key) or Map.has_key?(payload, field)
          end)

        case missing do
          [] -> :ok
          fields -> {:warn, fields}
        end

      {:error, :unknown_kind} ->
        :ok
    end
  end

  @doc """
  Get the default classification for a kind.
  """
  @spec default_classification(kind_name()) ::
          {:ok, :safe | :controlled | :dangerous} | {:error, :unknown_kind}
  def default_classification(kind_name) when is_atom(kind_name) do
    case lookup(kind_name) do
      {:ok, module} -> {:ok, module.default_classification()}
      {:error, _} = error -> error
    end
  end

  @doc """
  Get the human-readable description for a kind.
  """
  @spec description(kind_name()) :: {:ok, String.t()} | {:error, :unknown_kind}
  def description(kind_name) when is_atom(kind_name) do
    case lookup(kind_name) do
      {:ok, module} -> {:ok, module.description()}
      {:error, _} = error -> error
    end
  end

  @doc """
  Returns true if the kind name is registered.
  """
  @spec valid?(kind_name()) :: boolean()
  def valid?(kind_name) when is_atom(kind_name) do
    case lookup(kind_name) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp ensure_table do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, [:set, :public, :named_table])
      register_builtins()
    end
  end

  defp register_builtins do
    builtins = [
      Lattice.Intents.Kind.Action,
      Lattice.Intents.Kind.Inquiry,
      Lattice.Intents.Kind.Maintenance,
      Lattice.Intents.Kind.IssueTriage,
      Lattice.Intents.Kind.PrFixup,
      Lattice.Intents.Kind.PrCreate
    ]

    Enum.each(builtins, fn module ->
      :ets.insert(@table_name, {module.name(), module})
    end)
  end
end
