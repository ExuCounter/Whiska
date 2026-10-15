defmodule Whiska.TellTest do
  @moduledoc """
  `whiska tell`: a letter from this repo's main session to another open
  house's, left in that house for its own delivery to type (ADR-0044).
  """
  # Serial: each house opens under the one VM-wide name `Whiska.Repo`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Delivery.Mode
  alias Whiska.OpenHouses
  alias Whiska.Storage
  alias Whiska.Tell

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-tell-#{Whiska.Test.Unique.id()}")
    platform = house(root, "platform", "w1:p1")
    whiska = house(root, "whiska", "w2:p1")
    record = Path.join(root, "houses")
    :ok = OpenHouses.write([platform, whiska], record)

    note = Path.join(root, "note.md")
    File.write!(note, "The sidebar's idle line should be orange.\n")
    on_exit(fn -> File.rm_rf!(root) end)

    opts = [open_houses: record, pids: [123], away_path: Path.join(root, "away")]
    {:ok, root: root, platform: platform, whiska: whiska, record: record, note: note, opts: opts}
  end

  defp house(root, name, pane) do
    main = Path.join(root, name)
    File.mkdir_p!(Path.join(main, ".git"))
    Storage.within(main, fn -> if pane, do: :ok = Storage.set_main_pane(pane) end)
    main
  end

  defp letters(main), do: Storage.within(main, &Storage.letters/0)

  test "copies the file into the other house and records it there", ctx do
    assert {:ok, said} = Tell.run(ctx.platform, "whiska", ctx.note, ctx.opts)
    assert said =~ "whiska's main session"

    assert [letter] = letters(ctx.whiska)
    assert letter.from_repo == "platform"
    assert letter.from_checkout == ctx.platform
    assert letter.typed_at == nil
    assert Path.dirname(letter.path) == Path.join(ctx.whiska, ".git/whiska/letters")
    assert File.read!(letter.path) == File.read!(ctx.note)
    assert File.stat!(letter.path).mode |> Bitwise.band(0o777) == 0o600
    assert letters(ctx.platform) == []
  end

  test "a house is named by its main checkout too", ctx do
    assert {:ok, _} = Tell.run(ctx.platform, ctx.whiska, ctx.note, ctx.opts)
    assert [_] = letters(ctx.whiska)
  end

  test "refuses this repo's own house", ctx do
    assert {:error, said} = Tell.run(ctx.platform, "platform", ctx.note, ctx.opts)
    assert said =~ "this repo"
    assert letters(ctx.platform) == []
  end

  test "an unknown name lists the open houses", ctx do
    assert {:error, said} = Tell.run(ctx.platform, "nope", ctx.note, ctx.opts)
    assert said =~ "nope"
    assert said =~ "platform, whiska"
  end

  test "two open houses with one name are named by their main checkout", ctx do
    other = house(Path.join(ctx.root, "elsewhere"), "whiska", "w3:p1")
    :ok = OpenHouses.write([ctx.platform, ctx.whiska, other], ctx.record)

    assert {:error, said} = Tell.run(ctx.platform, "whiska", ctx.note, ctx.opts)
    assert said =~ ctx.whiska
    assert said =~ other
    assert letters(ctx.whiska) == []
  end

  test "with no owl running no house is open", ctx do
    opts = Keyword.put(ctx.opts, :pids, [])
    assert {:error, said} = Tell.run(ctx.platform, "whiska", ctx.note, opts)
    assert said =~ "owl"
    assert letters(ctx.whiska) == []
  end

  test "refuses a house with no main session recorded", ctx do
    quiet = house(ctx.root, "quiet", nil)
    :ok = OpenHouses.write([ctx.platform, quiet], ctx.record)

    assert {:error, said} = Tell.run(ctx.platform, "quiet", ctx.note, ctx.opts)
    assert said =~ "whiska start"
    assert letters(quiet) == []
  end

  test "refuses a house whose database is gone, and makes none", ctx do
    gone = Path.join(ctx.root, "gone")
    File.mkdir_p!(Path.join(gone, ".git"))
    :ok = OpenHouses.write([ctx.platform, gone], ctx.record)

    assert {:error, said} = Tell.run(ctx.platform, "gone", ctx.note, ctx.opts)
    assert said =~ "no house at #{gone}"
    refute File.exists?(Storage.database_path(gone))
  end

  test "refuses a file it cannot read", ctx do
    missing = Path.join(ctx.root, "missing.md")
    assert {:error, said} = Tell.run(ctx.platform, "whiska", missing, ctx.opts)
    assert said =~ "missing.md"
    assert letters(ctx.whiska) == []
  end

  test "refuses an empty file", ctx do
    File.write!(ctx.note, "  \n")
    assert {:error, said} = Tell.run(ctx.platform, "whiska", ctx.note, ctx.opts)
    assert said =~ "empty"
    assert letters(ctx.whiska) == []
  end

  test "says the letter waits while the person is away", ctx do
    :ok = Mode.set_away(ctx.opts[:away_path])
    assert {:ok, said} = Tell.run(ctx.platform, "whiska", ctx.note, ctx.opts)
    assert said =~ "resume"
  end

  test "the CLI runs it from the repo, and fails when no such house is open", ctx do
    {_, 0} = System.cmd("git", ["init", "-q", ctx.platform])

    {code, err} =
      with_io(:stderr, fn -> CLI.run(["tell", "whiska", ctx.note], ctx.platform) end)

    assert code == 1
    assert err =~ ~r/no owl|no open house/
  end
end
