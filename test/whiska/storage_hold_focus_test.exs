defmodule Whiska.StorageHoldFocusTest do
  @moduledoc """
  What the delivery modes add to storage (ADR-next-the-person-decides-what-reaches-them):
  a mouse the person put on hold is a stamp on its record, and a house's focus
  is a column on its one row.
  """
  use ExUnit.Case, async: true

  alias Whiska.Schema.Mouse
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-hold-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, handle} = Storage.open(main, name: nil)
    on_exit(fn -> Storage.close(handle) end)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "b"})
    {:ok, main: main}
  end

  describe "a held mouse" do
    test "is not held until the person says so" do
      assert Storage.mouse("m1").held_at == nil
      assert Storage.held_ids() == MapSet.new()
    end

    test "hold/1 stamps the record and held_ids/0 lists it" do
      assert {:ok, %Mouse{held_at: %DateTime{}}} = Storage.hold("m1")
      assert Storage.held_ids() == MapSet.new(["m1"])
    end

    test "holding twice keeps the first stamp" do
      {:ok, %Mouse{held_at: first}} = Storage.hold("m1")
      Process.sleep(1_100)
      {:ok, %Mouse{held_at: again}} = Storage.hold("m1")
      assert again == first
    end

    test "lift_hold/1 clears it" do
      {:ok, _} = Storage.hold("m1")
      assert {:ok, %Mouse{held_at: nil}} = Storage.lift_hold("m1")
      assert Storage.held_ids() == MapSet.new()
    end

    test "lifting a hold that was never there is fine" do
      assert {:ok, %Mouse{held_at: nil}} = Storage.lift_hold("m1")
    end

    test "a mouse nobody has a record of cannot be held" do
      assert {:error, :no_such_mouse} = Storage.hold("nobody")
      assert {:error, :no_such_mouse} = Storage.lift_hold("nobody")
    end

    test "a dead mouse's hold is not listed: there is nothing left to stop" do
      {:ok, _} = Storage.hold("m1")
      {:ok, _} = Storage.mark_dead("m1")
      assert Storage.held_ids() == MapSet.new()
    end
  end

  describe "a house's focus" do
    test "is nil until the person sets one" do
      assert Storage.focus() == nil
    end

    test "set_focus/1 records the mouse and focus/0 reads it back" do
      assert :ok = Storage.set_focus("m1")
      assert Storage.focus() == "m1"
    end

    test "setting it again replaces it: one focus per house" do
      :ok = Storage.set_focus("m1")
      :ok = Storage.set_focus("m2")
      assert Storage.focus() == "m2"
    end

    test "set_focus(nil) clears it" do
      :ok = Storage.set_focus("m1")
      :ok = Storage.set_focus(nil)
      assert Storage.focus() == nil
    end

    test "the focus survives the main session being recorded afterwards" do
      :ok = Storage.set_focus("m1")
      :ok = Storage.set_main_pane("w1:p2")
      assert Storage.focus() == "m1"
      assert Storage.main_pane() == "w1:p2"
    end
  end
end
