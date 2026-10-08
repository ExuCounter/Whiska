defmodule Whiska.Hook.UserPromptSubmitTest do
  @moduledoc """
  The take (ADR-0080): a prompt submitted in a
  mouse's own session hands over the answer the person saved for it, and
  stamps it taken.
  """
  # Serial: the code under test opens the house under the one VM-wide name
  # `Whiska.Repo`, and the tests set HERDR_PANE_ID in the OS env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.AnswerFlag
  alias Whiska.FinishFlag
  alias Whiska.Hook.UserPromptSubmit
  alias Whiska.Marker
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-ups-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git/worktrees/feat-thing"))
    File.mkdir_p!(worktree)
    File.write!(Path.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/feat-thing\n")
    {:ok, mouse_id} = Marker.read_or_mint(worktree)

    was = System.get_env("HERDR_PANE_ID")
    System.put_env("HERDR_PANE_ID", "w1:p7")

    on_exit(fn ->
      File.rm_rf!(root)
      if was, do: System.put_env("HERDR_PANE_ID", was), else: System.delete_env("HERDR_PANE_ID")
    end)

    {:ok, main: main, worktree: worktree, mouse_id: mouse_id}
  end

  defp in_house(main, fun) do
    {:ok, handle} = Storage.open(main, name: :seed)

    try do
      fun.()
    after
      Storage.close(handle)
    end
  end

  defp seed(main, worktree, mouse_id, fun) do
    in_house(main, fn ->
      {:ok, _} =
        Storage.record_mouse(%{mouse_id: mouse_id, path: worktree, branch: "feat-thing"})

      fun.()
    end)
  end

  defp ask(mouse_id, text) do
    {:ok, q} = Storage.record_question(%{mouse_id: mouse_id, text: text, kind: "needs-decision"})
    q
  end

  defp prompt(cwd), do: JSON.encode!(%{"cwd" => cwd, "prompt" => "🐱 The person answered #1"})

  defp context(json) do
    assert %{
             "hookSpecificOutput" => %{
               "hookEventName" => "UserPromptSubmit",
               "additionalContext" => context
             }
           } = JSON.decode!(json)

    context
  end

  test "hands the mouse its saved answer, whole, and stamps it taken", %{
    main: main,
    worktree: worktree,
    mouse_id: mouse_id
  } do
    seed(main, worktree, mouse_id, fn ->
      q = ask(mouse_id, "Two ways.\n\nWhich store?\n[worktree-status: needs-decision]")
      {:ok, _} = Storage.answer(q.id, "SQLite.\n\n- keep the schema\n- no Postgres")
    end)

    :ok = AnswerFlag.set(worktree)

    context = context(UserPromptSubmit.run(prompt(worktree)))
    assert context =~ "#1"
    assert context =~ "SQLite.\n\n- keep the schema\n- no Postgres"

    in_house(main, fn ->
      assert %DateTime{} = Storage.question(1).taken_at
      assert %DateTime{} = Storage.mouse(mouse_id).worked_at
    end)

    refute AnswerFlag.set?(worktree)
  end

  test "a second prompt hands nothing over again", %{
    main: main,
    worktree: worktree,
    mouse_id: mouse_id
  } do
    seed(main, worktree, mouse_id, fn ->
      q = ask(mouse_id, "?")
      {:ok, _} = Storage.answer(q.id, "yes")
    end)

    assert is_binary(UserPromptSubmit.run(prompt(worktree)))
    assert UserPromptSubmit.run(prompt(worktree)) == :none
  end

  test "never hands over an answer its mouse has moved past (ADR-0005)", %{
    main: main,
    worktree: worktree,
    mouse_id: mouse_id
  } do
    seed(main, worktree, mouse_id, fn ->
      q = ask(mouse_id, "?")
      {:ok, _} = Storage.answer(q.id, "yes")
      ask(mouse_id, "a newer one")
    end)

    :ok = AnswerFlag.set(worktree)

    assert UserPromptSubmit.run(prompt(worktree)) == :none
    in_house(main, fn -> assert Storage.question(1).taken_at == nil end)
    refute AnswerFlag.set?(worktree)
  end

  test "hands nothing over to another mouse's session", %{
    main: main,
    worktree: worktree,
    mouse_id: mouse_id
  } do
    seed(main, worktree, mouse_id, fn ->
      {:ok, _} =
        Storage.record_mouse(%{mouse_id: "other", path: "/elsewhere", branch: "feat-other"})

      q = ask("other", "?")
      {:ok, _} = Storage.answer(q.id, "yes")
    end)

    assert UserPromptSubmit.run(prompt(worktree)) == :none
  end

  test "is silent outside a worktree", %{main: main, worktree: worktree, mouse_id: mouse_id} do
    seed(main, worktree, mouse_id, fn ->
      q = ask(mouse_id, "?")
      {:ok, _} = Storage.answer(q.id, "yes")
    end)

    assert UserPromptSubmit.run(prompt(main)) == :none
  end

  test "takes nothing in the main session's pane, wherever it started (ADR-0053)", %{
    main: main,
    worktree: worktree,
    mouse_id: mouse_id
  } do
    seed(main, worktree, mouse_id, fn ->
      Storage.set_main_pane("w1:p7")
      q = ask(mouse_id, "?")
      {:ok, _} = Storage.answer(q.id, "yes")
    end)

    :ok = AnswerFlag.set(worktree)

    assert UserPromptSubmit.run(prompt(worktree)) == :none
    in_house(main, fn -> assert Storage.question(1).taken_at == nil end)
    assert AnswerFlag.set?(worktree)
  end

  test "never hands a mouse's answer to another worktree carrying a copy of its marker", %{
    main: main,
    worktree: worktree,
    mouse_id: mouse_id
  } do
    seed(main, worktree, mouse_id, fn ->
      q = ask(mouse_id, "?")
      {:ok, _} = Storage.answer(q.id, "yes")
    end)

    copy = Path.join(main, "worktrees/feat-copy")
    File.mkdir_p!(Path.join(main, ".git/worktrees/feat-copy"))
    File.mkdir_p!(copy)
    File.write!(Path.join(copy, ".git"), "gitdir: #{main}/.git/worktrees/feat-copy\n")
    File.cp!(Marker.path(worktree), Marker.path(copy))

    assert UserPromptSubmit.run(prompt(copy)) == :none
    in_house(main, fn -> assert Storage.question(1).taken_at == nil end)
  end

  test "`whiska hook user-prompt-submit` reads stdin, prints the hand-over, exits 0", %{
    main: main,
    worktree: worktree,
    mouse_id: mouse_id
  } do
    seed(main, worktree, mouse_id, fn ->
      q = ask(mouse_id, "?")
      {:ok, _} = Storage.answer(q.id, "yes")
    end)

    output =
      capture_io([input: prompt(worktree), capture_prompt: false], fn ->
        send(self(), {:status, Whiska.CLI.run(["hook", "user-prompt-submit"])})
      end)

    assert_received {:status, 0}
    assert context(output) =~ "yes"
  end

  describe "in the main session, after a finished line (ADR-0008)" do
    setup %{main: main, worktree: worktree, mouse_id: mouse_id} do
      seed(main, worktree, mouse_id, fn ->
        Storage.set_main_pane("w1:p7")
        {:ok, q} = Storage.record_question(%{mouse_id: mouse_id, text: "Done.", kind: "done"})
        {:ok, _} = Storage.mark_sent(q.id)
      end)

      :ok = FinishFlag.set(main)
      :ok
    end

    defp said(cwd, words), do: JSON.encode!(%{"cwd" => cwd, "prompt" => words})

    test "the person's next prompt settles the finished line and lowers the flag", %{main: main} do
      in_house(main, fn ->
        {:ok, _} = Storage.record_mouse(%{mouse_id: "held", path: "/elsewhere", branch: "b"})
        {:ok, q} = Storage.record_question(%{mouse_id: "held", text: "?", kind: "needs-decision"})
        {:ok, _} = Storage.mark_sent(q.id)
      end)

      assert UserPromptSubmit.run(said(main, "A")) == :none

      in_house(main, fn ->
        assert Storage.question(1).status == "closed"
        assert Storage.question(2).status == "sent"
      end)

      refute FinishFlag.set?(main)
    end

    test "a flag with nothing left out is lowered from any pane", %{main: main} do
      in_house(main, fn -> {:ok, _} = Storage.close_question(1) end)
      System.put_env("HERDR_PANE_ID", "w9:p9")

      assert UserPromptSubmit.run(said(main, "A")) == :none
      refute FinishFlag.set?(main)
    end

    test "the owl's own line settles nothing", %{main: main} do
      assert UserPromptSubmit.run(said(main, "🐱 feat-thing finished · #1")) == :none

      in_house(main, fn -> assert Storage.question(1).status == "sent" end)
      assert FinishFlag.set?(main)
    end

    test "a prompt in another pane settles nothing", %{main: main} do
      System.put_env("HERDR_PANE_ID", "w9:p9")

      assert UserPromptSubmit.run(said(main, "A")) == :none

      in_house(main, fn -> assert Storage.question(1).status == "sent" end)
      assert FinishFlag.set?(main)
    end
  end

  test "a malformed payload is a no-op, never a crash" do
    {result, _err} = with_io(:stderr, fn -> UserPromptSubmit.run("{not json") end)
    assert result == :none
  end
end
