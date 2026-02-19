defmodule Lattice.Repo do
  use Ecto.Repo,
    otp_app: :lattice,
    adapter: Ecto.Adapters.Postgres
end
