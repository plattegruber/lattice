defmodule Lattice.Sprites.ExecSessionTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Sprites.ExecSession

  describe "exec_topic/1" do
    test "returns namespaced topic" do
      assert ExecSession.exec_topic("exec_abc123") == "exec:exec_abc123"
    end
  end
end
