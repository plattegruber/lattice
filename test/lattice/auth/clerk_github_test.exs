defmodule Lattice.Auth.ClerkGitHubTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Auth.ClerkGitHub

  describe "fetch_token/1" do
    test "returns error when clerk secret key is not configured" do
      prev = Application.get_env(:lattice, :auth)
      Application.put_env(:lattice, :auth, provider: Lattice.MockAuth)

      prev_env = System.get_env("CLERK_SECRET_KEY")
      System.delete_env("CLERK_SECRET_KEY")

      on_exit(fn ->
        Application.put_env(:lattice, :auth, prev)
        if prev_env, do: System.put_env("CLERK_SECRET_KEY", prev_env)
      end)

      assert {:error, :clerk_secret_key_not_configured} = ClerkGitHub.fetch_token("user_123")
    end
  end

  describe "invalidate/1" do
    test "clears cached token" do
      # Directly populate the ETS cache
      table = :lattice_clerk_github_tokens

      try do
        :ets.new(table, [:set, :public, :named_table])
      rescue
        ArgumentError -> :ok
      end

      :ets.insert(table, {"user_test", "cached-token", System.monotonic_time(:millisecond)})

      assert [{_, "cached-token", _}] = :ets.lookup(table, "user_test")

      ClerkGitHub.invalidate("user_test")

      assert [] = :ets.lookup(table, "user_test")
    end
  end
end
