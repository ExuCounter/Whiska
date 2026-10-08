defmodule Whiska.CLILedgerTest do
  @moduledoc """
  `whiska ledger`: the session it runs in is the one Claude Code names in
  `CLAUDE_CODE_SESSION_ID`, its transcript found under the `:user_home` setting.
  """
  # Serial: the tests move the global `:user_home` and set an OS env var.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI

  setup do
    home = Path.join(System.tmp_dir!(), "whiska-clil-#{System.unique_integer([:positive])}")
    project = Path.join([home, ".claude", "projects", "-w"])
    File.mkdir_p!(project)

    previous = Application.get_env(:whiska, :user_home)
    was_session = System.get_env("CLAUDE_CODE_SESSION_ID")
    Application.put_env(:whiska, :user_home, home)

    on_exit(fn ->
      Application.put_env(:whiska, :user_home, previous)

      if was_session,
        do: System.put_env("CLAUDE_CODE_SESSION_ID", was_session),
        else: System.delete_env("CLAUDE_CODE_SESSION_ID")

      File.rm_rf!(home)
    end)

    File.write!(
      Path.join(project, "s1.jsonl"),
      JSON.encode!(%{
        "type" => "assistant",
        "timestamp" => "2026-10-08T08:00:00.000Z",
        "message" => %{
          "id" => "m1",
          "model" => "claude-opus-5-5",
          "stop_reason" => "end_turn",
          "usage" => %{
            "input_tokens" => 5,
            "cache_creation_input_tokens" => 1_000,
            "output_tokens" => 10
          },
          "content" => [%{"type" => "text"}]
        }
      }) <> "\n"
    )

    :ok
  end

  test "prints this session's ledger" do
    System.put_env("CLAUDE_CODE_SESSION_ID", "s1")

    out = capture_io(fn -> assert CLI.run(["ledger"]) == 0 end)

    assert out =~ "mouse (whole session) · claude-opus-5-5 · new 1k · reads 0 · 1 step"
  end

  test "prints it as data with --json" do
    System.put_env("CLAUDE_CODE_SESSION_ID", "s1")

    out = capture_io(fn -> assert CLI.run(["ledger", "--json"]) == 0 end)

    assert %{"version" => 1, "mouse" => %{"new_tokens" => 1_015}} = JSON.decode!(out)
  end

  test "outside a Claude Code session it says so and fails" do
    System.delete_env("CLAUDE_CODE_SESSION_ID")

    err = capture_io(:stderr, fn -> assert CLI.run(["ledger"]) == 1 end)

    assert err =~ "CLAUDE_CODE_SESSION_ID"
  end

  test "a session with no transcript on disk says so and fails" do
    System.put_env("CLAUDE_CODE_SESSION_ID", "gone")

    err = capture_io(:stderr, fn -> assert CLI.run(["ledger"]) == 1 end)

    assert err =~ "no transcript"
  end
end
