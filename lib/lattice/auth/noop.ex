defmodule Lattice.Auth.Noop do
  @moduledoc """
  Permissive auth provider that grants operator access to all requests.

  Used when no real auth provider (e.g. Clerk) is configured. All tokens
  are accepted and mapped to a default operator with admin role.

  This is the fallback for development and early production deployments
  before Clerk is set up.
  """

  @behaviour Lattice.Auth

  alias Lattice.Auth.Operator

  @impl true
  def verify_token(_token) do
    {:ok, Operator.new("noop", "Operator", :admin)}
  end
end
