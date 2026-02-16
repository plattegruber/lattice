defmodule LatticeWeb.Plugs.Auth do
  @moduledoc """
  Plug that authenticates API requests and assigns the operator.

  Reads the `Authorization: Bearer <token>` header, verifies the token
  via the configured auth provider, and assigns the resulting Operator
  struct to `conn.assigns.current_operator`.

  If authentication fails, responds with 401 Unauthorized.

  ## Usage

  In the router:

      pipeline :authenticated_api do
        plug :accepts, ["json"]
        plug LatticeWeb.Plugs.Auth
      end

  In controllers:

      def index(conn, _params) do
        operator = conn.assigns.current_operator
        # ...
      end
  """

  import Plug.Conn

  alias Lattice.Auth

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case extract_token(conn) do
      {:ok, token} ->
        case Auth.verify_token(token) do
          {:ok, operator} ->
            assign(conn, :current_operator, operator)

          {:error, _reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
            |> halt()
        end

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "missing_authorization_header"}))
        |> halt()
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> :error
    end
  end
end
