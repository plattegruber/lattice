defmodule LatticeWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use LatticeWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint LatticeWeb.Endpoint

      use LatticeWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import LatticeWeb.ConnCase
    end
  end

  @doc """
  Sets up session data so a conn passes the LiveView AuthHook.

  Puts the minimal operator session keys required by `LatticeWeb.Hooks.AuthHook`.
  Call this in test setups that exercise authenticated LiveView routes.
  """
  def log_in_conn(conn) do
    conn
    |> Plug.Test.init_test_session(%{
      "operator_id" => "test-operator",
      "operator_name" => "Test Operator",
      "operator_role" => "admin"
    })
  end

  setup _tags do
    # Stub MockAuth so all authenticated API requests succeed by default.
    # Individual tests can override with Mox.expect/3 if needed.
    Mox.stub(Lattice.MockAuth, :verify_token, fn _token ->
      {:ok, %Lattice.Auth.Operator{id: "test-operator", name: "Test Operator", role: :admin}}
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
