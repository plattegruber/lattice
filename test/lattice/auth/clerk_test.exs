defmodule Lattice.Auth.ClerkTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Auth.Clerk

  # These tests verify the JWT parsing and validation logic without hitting
  # Clerk's API. We use malformed and expired tokens to test error paths.
  # Full integration testing with real Clerk tokens requires a running Clerk
  # instance and is covered by integration tests.

  describe "verify_token/1 with invalid tokens" do
    test "rejects non-string token" do
      assert {:error, :invalid_token} = Clerk.verify_token(123)
      assert {:error, :invalid_token} = Clerk.verify_token(nil)
    end

    test "rejects malformed token (not 3 parts)" do
      assert {:error, :malformed_token} = Clerk.verify_token("not-a-jwt")
      assert {:error, :malformed_token} = Clerk.verify_token("two.parts")
    end

    test "rejects token with invalid base64 in header" do
      assert {:error, :malformed_token} = Clerk.verify_token("!!!.payload.sig")
    end

    test "rejects token with non-RS256 algorithm" do
      # Header: {"alg": "HS256", "typ": "JWT"}
      header = Base.url_encode64(~s({"alg":"HS256","typ":"JWT"}), padding: false)
      payload = Base.url_encode64(~s({"sub":"user_1","exp":9999999999}), padding: false)
      token = "#{header}.#{payload}.fake-signature"

      assert {:error, :unsupported_algorithm} = Clerk.verify_token(token)
    end

    test "rejects token when JWKS fetch fails (no CLERK_SECRET_KEY)" do
      # Ensure no secret key is set
      original = System.get_env("CLERK_SECRET_KEY")
      System.delete_env("CLERK_SECRET_KEY")

      # Header: {"alg": "RS256", "typ": "JWT", "kid": "test-kid"}
      header = Base.url_encode64(~s({"alg":"RS256","typ":"JWT","kid":"test-kid"}), padding: false)
      payload = Base.url_encode64(~s({"sub":"user_1","exp":9999999999}), padding: false)
      token = "#{header}.#{payload}.fake-signature"

      assert {:error, :clerk_secret_key_not_configured} = Clerk.verify_token(token)

      # Restore original env
      if original, do: System.put_env("CLERK_SECRET_KEY", original)
    end
  end
end
