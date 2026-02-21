defmodule Lattice.Sprites.FileWriterTest do
  use ExUnit.Case
  @moduletag :unit

  import Mox

  alias Lattice.Sprites.FileWriter

  setup :set_mox_global
  setup :verify_on_exit!

  describe "write_file/3" do
    test "writes small content in a single chunk" do
      content = "hello world"
      encoded = Base.encode64(content)

      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn _name, cmd ->
        assert cmd == "printf '%s' '#{encoded}' > /tmp/test.txt.b64"
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec, fn _name, cmd ->
        assert cmd == "base64 -d /tmp/test.txt.b64 > /tmp/test.txt"
        {:ok, %{output: "", exit_code: 0}}
      end)

      assert :ok = FileWriter.write_file("test-sprite", content, "/tmp/test.txt")
    end

    test "splits large content into multiple chunks" do
      # Generate content that base64-encodes to more than 50_000 chars
      content = String.duplicate("x", 40_000)
      encoded = Base.encode64(content)
      chunks = FileWriter.chunk_string(encoded, 50_000)

      assert length(chunks) > 1

      # First chunk: write (>)
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn _name, cmd ->
        assert cmd =~ ~r/> \/tmp\/big\.txt\.b64$/
        {:ok, %{output: "", exit_code: 0}}
      end)

      # Remaining chunks: append (>>)
      for _chunk <- tl(chunks) do
        Lattice.Capabilities.MockSprites
        |> expect(:exec, fn _name, cmd ->
          assert cmd =~ ~r/>> \/tmp\/big\.txt\.b64$/
          {:ok, %{output: "", exit_code: 0}}
        end)
      end

      # Final decode step
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn _name, cmd ->
        assert cmd == "base64 -d /tmp/big.txt.b64 > /tmp/big.txt"
        {:ok, %{output: "", exit_code: 0}}
      end)

      assert :ok = FileWriter.write_file("test-sprite", content, "/tmp/big.txt")
    end

    test "returns error when first chunk write fails" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn _name, _cmd ->
        {:error, :not_found}
      end)

      assert {:error, :not_found} =
               FileWriter.write_file("test-sprite", "content", "/tmp/fail.txt")
    end

    test "returns error when decode step fails" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn _name, _cmd ->
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec, fn _name, _cmd ->
        {:error, :decode_failed}
      end)

      assert {:error, :decode_failed} =
               FileWriter.write_file("test-sprite", "content", "/tmp/fail.txt")
    end
  end

  describe "chunk_string/2" do
    test "returns single chunk for small strings" do
      assert FileWriter.chunk_string("abc", 10) == ["abc"]
    end

    test "splits string into correctly sized chunks" do
      chunks = FileWriter.chunk_string("abcdefghij", 3)
      assert chunks == ["abc", "def", "ghi", "j"]
    end

    test "handles empty string" do
      assert FileWriter.chunk_string("", 10) == []
    end
  end
end
