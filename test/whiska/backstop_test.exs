defmodule Whiska.BackstopTest do
  @moduledoc """
  The mark a house leaves when its backstop collected what the idle trigger
  should have (ADR-0036). It lives in the house, beside the doorstep, because
  the doctor is repo-scoped and reads it from a different process.
  """
  use ExUnit.Case, async: true

  alias Whiska.Backstop

  setup do
    main = Path.join(System.tmp_dir!(), "whiska-backstop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(main) end)
    {:ok, main: main}
  end

  test "no mark is nil", %{main: main} do
    assert Backstop.read(main) == nil
  end

  test "what was recorded is what is read back", %{main: main} do
    at = DateTime.utc_now() |> DateTime.truncate(:second)
    :ok = Backstop.record(main, 3, at)

    assert %{count: 3, last: ^at} = Backstop.read(main)
  end

  test "a later record replaces the earlier one", %{main: main} do
    at = DateTime.utc_now() |> DateTime.truncate(:second)
    :ok = Backstop.record(main, 1, DateTime.add(at, -60))
    :ok = Backstop.record(main, 2, at)

    assert %{count: 2, last: ^at} = Backstop.read(main)
  end

  test "clearing removes it, and clearing nothing is fine", %{main: main} do
    :ok = Backstop.clear(main)
    :ok = Backstop.record(main, 1, DateTime.utc_now())
    :ok = Backstop.clear(main)

    assert Backstop.read(main) == nil
  end

  test "a mark that will not parse reads as no mark", %{main: main} do
    :ok = Backstop.record(main, 1, DateTime.utc_now())
    File.write!(Backstop.path(main), "half a lin")

    assert Backstop.read(main) == nil
  end
end
