defmodule LatticeWeb.Plugs.WebhookSignatureTest do
  use LatticeWeb.ConnCase, async: true

  @moduletag :unit

  alias LatticeWeb.Plugs.WebhookSignature

  @secret "test-webhook-secret"

  defp sign(body, secret \\ @secret) do
    :crypto.mac(:hmac, :sha256, secret, body)
    |> Base.encode16(case: :lower)
  end

  defp build_signed_conn(body) do
    signature = sign(body)

    :post
    |> Plug.Test.conn("/api/webhooks/github", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=#{signature}")
    |> Map.update!(:assigns, &Map.put(&1, :raw_body, [body]))
  end

  describe "call/2" do
    test "passes through with valid signature" do
      body = ~s({"action":"opened"})
      conn = build_signed_conn(body)

      result = WebhookSignature.call(conn, [])

      refute result.halted
    end

    test "rejects invalid signature" do
      body = ~s({"action":"opened"})

      conn =
        :post
        |> Plug.Test.conn("/api/webhooks/github", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=invalid")
        |> Map.update!(:assigns, &Map.put(&1, :raw_body, [body]))

      result = WebhookSignature.call(conn, [])

      assert result.halted
      assert result.status == 401
    end

    test "rejects when X-Hub-Signature-256 header is missing" do
      body = ~s({"action":"opened"})

      conn =
        :post
        |> Plug.Test.conn("/api/webhooks/github", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.update!(:assigns, &Map.put(&1, :raw_body, [body]))

      result = WebhookSignature.call(conn, [])

      assert result.halted
      assert result.status == 401
    end

    test "rejects when raw body is not available" do
      body = ~s({"action":"opened"})
      signature = sign(body)

      conn =
        :post
        |> Plug.Test.conn("/api/webhooks/github", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=#{signature}")

      result = WebhookSignature.call(conn, [])

      assert result.halted
      assert result.status == 401
    end

    test "rejects when webhook secret is not configured" do
      original = Application.get_env(:lattice, :webhooks)
      Application.put_env(:lattice, :webhooks, Keyword.put(original, :github_secret, nil))

      on_exit(fn -> Application.put_env(:lattice, :webhooks, original) end)

      body = ~s({"action":"opened"})
      conn = build_signed_conn(body)

      result = WebhookSignature.call(conn, [])

      assert result.halted
      assert result.status == 401
    end
  end
end
