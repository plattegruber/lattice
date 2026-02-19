defmodule LatticeWeb.AuditLiveTest do
  use LatticeWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Lattice.Safety.Audit

  @moduletag :unit

  describe "audit view rendering" do
    test "renders audit page with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/audit")
      assert html =~ "Audit Log"
    end

    test "shows empty state message initially", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/audit")
      assert html =~ "No audit entries yet"
    end

    test "shows filter controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/audit")
      assert html =~ "Capability"
      assert html =~ "Classification"
      assert html =~ "Result"
    end
  end

  describe "real-time updates" do
    test "displays new audit entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      # Emit an audit entry
      Audit.log(:sprites, :list_sprites, :safe, :ok, :system, args: ["test"])

      # Give PubSub time to deliver
      Process.sleep(50)

      html = render(view)
      assert html =~ "sprites"
      assert html =~ "list_sprites"
    end

    test "shows entry count badge", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      Audit.log(:sprites, :wake, :controlled, :ok, :human, args: ["s1"])
      Audit.log(:github, :create_issue, :controlled, {:error, :timeout}, :system)
      Process.sleep(50)

      html = render(view)
      assert html =~ "2 entries"
    end
  end

  describe "filtering" do
    test "filters by result", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      Audit.log(:sprites, :list_sprites, :safe, :ok, :system)
      Audit.log(:github, :create_issue, :controlled, {:error, :timeout}, :system)
      Process.sleep(50)

      # Filter to errors only
      html =
        view
        |> element("form")
        |> render_change(%{"capability" => "", "classification" => "", "result" => "error"})

      assert html =~ "create_issue"
      refute html =~ "list_sprites"
    end
  end
end
