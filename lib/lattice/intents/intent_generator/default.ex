defmodule Lattice.Intents.IntentGenerator.Default do
  @moduledoc """
  Default observation-to-intent generator.

  Evaluates observations and generates maintenance intents when conditions
  warrant action. The rules are intentionally conservative — most observations
  produce no intent.

  ## Rules

  | Type             | Severity         | Result                          |
  |------------------|------------------|---------------------------------|
  | `:anomaly`       | `:high`          | Maintenance intent (investigate)|
  | `:anomaly`       | `:critical`      | Maintenance intent (investigate)|
  | `:recommendation`| `:medium`+       | Maintenance intent (improve)    |
  | All others       | Any              | `:skip`                         |

  """

  @behaviour Lattice.Intents.IntentGenerator

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Observation

  @impl true
  def generate(%Observation{type: :anomaly, severity: severity} = obs)
      when severity in [:high, :critical] do
    source = %{type: :sprite, id: obs.sprite_id}

    Intent.new_maintenance(source,
      summary: "Investigate anomaly: #{summary_from_data(obs.data)}",
      payload: %{
        "trigger" => "observation",
        "observation_type" => to_string(obs.type),
        "severity" => to_string(obs.severity),
        "observation_data" => obs.data
      },
      metadata: %{
        "observation_id" => obs.id,
        "generated_from" => "observation"
      }
    )
  end

  def generate(%Observation{type: :recommendation, severity: severity} = obs)
      when severity in [:medium, :high, :critical] do
    source = %{type: :sprite, id: obs.sprite_id}

    Intent.new_maintenance(source,
      summary: "Recommendation: #{summary_from_data(obs.data)}",
      payload: %{
        "trigger" => "observation",
        "observation_type" => to_string(obs.type),
        "severity" => to_string(obs.severity),
        "observation_data" => obs.data
      },
      metadata: %{
        "observation_id" => obs.id,
        "generated_from" => "observation"
      }
    )
  end

  def generate(%Observation{}), do: :skip

  defp summary_from_data(%{"message" => message}) when is_binary(message), do: message
  defp summary_from_data(%{"description" => desc}) when is_binary(desc), do: desc
  defp summary_from_data(_data), do: "observation requires attention"
end
