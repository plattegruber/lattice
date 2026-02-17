defmodule Lattice.Intents.IntentGenerator do
  @moduledoc """
  Behaviour for generating Intents from Observations.

  Observations are facts about the world. When conditions warrant action,
  a generator converts an observation into an intent proposal that enters
  the governance pipeline.

  ## Configuration

  The active generator is configured in application config:

      config :lattice, :intent_generator, Lattice.Intents.IntentGenerator.Default

  ## Implementing a custom generator

      defmodule MyApp.CustomGenerator do
        @behaviour Lattice.Intents.IntentGenerator

        @impl true
        def generate(%Observation{} = observation) do
          # Custom logic here
          :skip
        end
      end

  """

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Observation

  @doc """
  Evaluate an observation and optionally generate an intent.

  Returns `{:ok, intent}` when the observation warrants action,
  or `:skip` when no intent should be generated.
  """
  @callback generate(Observation.t()) :: {:ok, Intent.t()} | :skip | {:error, term()}

  @doc """
  Generate an intent from an observation using the configured generator.

  Delegates to the module configured in `:lattice, :intent_generator`,
  defaulting to `Lattice.Intents.IntentGenerator.Default`.
  """
  @spec generate(Observation.t()) :: {:ok, Intent.t()} | :skip | {:error, term()}
  def generate(%Observation{} = observation) do
    generator().generate(observation)
  end

  defp generator do
    Application.get_env(:lattice, :intent_generator, Lattice.Intents.IntentGenerator.Default)
  end
end
