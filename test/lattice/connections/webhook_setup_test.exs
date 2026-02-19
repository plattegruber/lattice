defmodule Lattice.Connections.WebhookSetupTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Connections.WebhookSetup

  describe "module" do
    test "exports create/3 and delete/2" do
      exports = WebhookSetup.__info__(:functions)
      assert {:create, 3} in exports
      assert {:delete, 2} in exports
    end
  end

  describe "create/3" do
    test "returns error on invalid token" do
      # Using a bad token will result in an HTTP error from GitHub
      # In unit tests without a mock server, this tests the error path
      result = WebhookSetup.create("test/repo", "invalid-token", "https://example.com")
      assert {:error, _} = result
    end
  end

  describe "delete/2" do
    test "returns ok when no webhook ID is stored" do
      # Clean up any existing webhook config
      prev = Application.get_env(:lattice, :webhooks, [])
      webhooks = Keyword.delete(prev, :github_webhook_id)
      Application.put_env(:lattice, :webhooks, webhooks)

      on_exit(fn -> Application.put_env(:lattice, :webhooks, prev) end)

      assert :ok = WebhookSetup.delete("test/repo", "some-token")
    end
  end
end
