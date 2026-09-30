defmodule Whiska.IsolatedTest do
  use ExUnit.Case, async: true

  alias Whiska.Isolated

  test "hands back whatever the work returned" do
    assert Isolated.run(fn -> {:ok, "a value"} end) == {:ok, "a value"}
  end

  test "work that raises is an error here, not a raise here" do
    assert {:error, _} = Isolated.run(fn -> raise "nope" end)
    assert {:error, _} = Isolated.run(fn -> exit(:boom) end)
  end

  test "a process the work linked to itself cannot take this one down" do
    assert {:error, _} =
             Isolated.run(fn ->
               spawn_link(fn -> exit(:corrupt) end)
               Process.sleep(1_000)
             end)

    assert Process.alive?(self())
  end

  test "work that never returns is an error, and is killed" do
    assert {:error, :timeout} = Isolated.run(fn -> Process.sleep(:infinity) end, 50)
  end
end
