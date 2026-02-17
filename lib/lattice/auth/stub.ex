defmodule Lattice.Auth.Stub do
  @moduledoc """
  Stub auth provider for development and testing.

  Returns a hardcoded operator for any token. The operator identity is
  read from application config, falling back to sensible defaults.

  ## Configuration

      config :lattice, :auth,
        provider: Lattice.Auth.Stub,
        stub_operator: %{
          id: "dev-operator",
          name: "Dev Operator",
          role: :admin
        }

  If no stub_operator config is present, defaults to an admin operator
  named "Dev Operator".
  """

  @behaviour Lattice.Auth

  alias Lattice.Auth.Operator

  @impl true
  def verify_token(_token) do
    config = Application.get_env(:lattice, :auth, [])
    stub_config = Keyword.get(config, :stub_operator, %{})

    id = Map.get(stub_config, :id, "dev-operator")
    name = Map.get(stub_config, :name, "Dev Operator")
    role = Map.get(stub_config, :role, :admin)

    Operator.new(id, name, role)
  end
end
