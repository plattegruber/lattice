defmodule Lattice.Repo do
  @moduledoc """
  Ecto repository for Lattice database operations.
  """

  use Ecto.Repo,
    otp_app: :lattice,
    adapter: Ecto.Adapters.Postgres
end
