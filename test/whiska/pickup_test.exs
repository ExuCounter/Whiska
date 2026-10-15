defmodule Whiska.PickupTest do
  @moduledoc """
  Picking up a turn that died (ADR-0067).

  A real house, a real doorstep, and herdr faked at the one boundary that
  allows it (ADR-0031). Most of these are about *not* typing anything: the owl
  starting a turn in a session nobody asked it to is what the preconditions
  exist to keep rare.

  Every sweep is given the instant it runs at, so a test says when a turn
  started, when the pane went quiet and when the owl looked, rather than
  sleeping.
  """
  use ExUnit.Case, async: true

  import Mox

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Pickup
  alias Whiska.Storage
  alias Whiska.Test.GitRepo
  alias Whiska.Transcript

  setup :verify_on_exit!

  @settle_ms 120_000
  @start ~U[2026-10-03 10:00:00Z]

  # A quiet pane before anything happens — the owl needs a memory of one to
  # read the next sighting as a turn starting — then the turn, then the pane
  # going quiet, then a sweep in between, then the first instant the settling
  # window is up. Sweeps are a backstop apart, as the house takes them.
  @before -60
  @worked 0
  @quiet 60
  @between 120
  @settled 180

  defp at(seconds), do: DateTime.add(@start, seconds, :second)

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-pickup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    repo = GitRepo.create(root)
    {:ok, handle} = Storage.open(repo.checkout, name: nil)

    on_exit(fn ->
      Storage.close(handle)
      File.rm_rf!(root)
    end)

    stub(Herdr, :read_screen, fn _, _ -> {:error, :no_screen} end)
    Process.put(:worktrees, :all)
    Process.put(:home, Path.join(root, "home"))

    {:ok, repo: repo}
  end

  defp mouse(repo, branch, opts \\ []) do
    path = Keyword.get_lazy(opts, :path, fn -> GitRepo.worktree(repo, branch) end)
    id = "m-#{branch}"
    {:ok, _} = Storage.record_mouse(%{mouse_id: id, path: path, branch: branch})
    ours(repo, [%{path: path, branch: branch, workspace_id: "ws-1"}])
    %{id: id, path: path, branch: branch}
  end

  # What herdr says are this checkout's own linked worktrees, which is what
  # bounds the owl to panes it has any business typing into.
  defp ours(repo, worktrees) do
    stub(Herdr, :worktrees, fn "/s", checkout ->
      ^checkout = repo.checkout
      {:ok, (Process.get(:worktrees) == :all && worktrees) || Process.get(:worktrees)}
    end)
  end

  defp panes(mouse, status, opts \\ []) do
    [
      %{
        pane_id: Keyword.get(opts, :pane_id, "w1:p1"),
        cwd: mouse.path,
        agent: Keyword.get(opts, :agent, "claude"),
        agent_status: status,
        title: nil,
        session: nil
      }
    ]
  end

  defp herdr(panes), do: Process.put(:panes, {:ok, panes})

  defp sweep(repo, seconds, seen, opts \\ []) do
    Pickup.sweep(%{
      main_checkout: repo.checkout,
      herdr: Herdr,
      socket: "/s",
      panes: Keyword.get_lazy(opts, :panes, fn -> Process.get(:panes, {:ok, []}) end),
      main_pane: Keyword.get(opts, :main_pane),
      seen: seen,
      last_sweep_at: Keyword.get_lazy(opts, :last_sweep_at, fn -> at(seconds - 60) end),
      max_gap_ms: Keyword.get(opts, :max_gap_ms, 180_000),
      settle_ms: Keyword.get(opts, :settle_ms, @settle_ms),
      user_home: Process.get(:home),
      now: at(seconds)
    })
  end

  # What Claude Code has written for this mouse's session so far, in its own
  # folder under a home of the test's own — the owl never sees the real one.
  defp transcript(mouse, entries) do
    dir = Transcript.project_dir(mouse.path, Process.get(:home))
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "session.jsonl"), Enum.join(entries, "\n") <> "\n")
  end

  defp said(text) do
    JSON.encode!(%{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "text", "text" => text}]}
    })
  end

  defp said(text, seconds) do
    text
    |> said()
    |> JSON.decode!()
    |> Map.put("timestamp", seconds |> at() |> DateTime.to_iso8601())
    |> JSON.encode!()
  end

  # Claude Code's own entry for a turn that gave up, of `kind`, written at
  # `:at` seconds when given, with a rate limit's reset `:resets_at` seconds.
  defp api_error(kind \\ "server_error", opts \\ []) do
    %{
      "type" => "assistant",
      "isSidechain" => false,
      "isApiErrorMessage" => true,
      "error" => kind,
      "message" => %{
        "model" => "<synthetic>",
        "content" => [%{"type" => "text", "text" => "API Error: The response stopped arriving."}]
      }
    }
    |> stamped(opts[:at])
    |> then(fn entry ->
      case opts[:resets_at] do
        nil -> entry
        s -> Map.put(entry, "quotaLimits", %{"resetsAt" => s |> at() |> DateTime.to_unix()})
      end
    end)
    |> JSON.encode!()
  end

  defp stamped(entry, nil), do: entry
  defp stamped(entry, s), do: Map.put(entry, "timestamp", s |> at() |> DateTime.to_iso8601())

  # The pickup line, as Claude Code records it once the session takes it.
  defp typed(text, seconds) do
    JSON.encode!(%{
      "type" => "user",
      "timestamp" => seconds |> at() |> DateTime.to_iso8601(),
      "message" => %{"role" => "user", "content" => text}
    })
  end

  defp backgrounded(task_id, seconds) do
    stamp = seconds |> at() |> DateTime.to_iso8601()

    [
      JSON.encode!(%{
        "type" => "assistant",
        "timestamp" => stamp,
        "message" => %{
          "content" => [%{"type" => "tool_use", "id" => "toolu_1", "name" => "Bash"}]
        }
      }),
      JSON.encode!(%{
        "type" => "user",
        "timestamp" => stamp,
        "toolUseResult" => %{"stdout" => "", "backgroundTaskId" => task_id},
        "message" => %{
          "content" => [%{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "x"}]
        }
      })
    ]
  end

  defp turn_duration, do: ~s({"type":"system","subtype":"turn_duration","durationMs":215204})

  defp look(repo, seconds, seen, mouse, status, opts \\ []) do
    herdr(panes(mouse, status, opts))
    sweep(repo, seconds, seen)
  end

  # The state every pickup starts from: a mouse seen working, then quiet, with
  # nothing of its collected in between.
  defp died(repo, mouse, opts \\ []) do
    quiet = Keyword.get(opts, :status, "done")
    {_, seen} = look(repo, @before, %{}, mouse, "idle", opts)
    {_, seen} = look(repo, @worked, seen, mouse, "working", opts)
    {_, seen} = look(repo, @quiet, seen, mouse, quiet, opts)
    {_, seen} = look(repo, @between, seen, mouse, quiet, opts)
    seen
  end

  defp question(mouse, opts) do
    {:ok, q} =
      Storage.record_question(%{
        mouse_id: mouse.id,
        text: Keyword.get(opts, :text, "all done"),
        kind: Keyword.get(opts, :kind, "done"),
        status: Keyword.get(opts, :status, "closed"),
        asked_at: opts |> Keyword.fetch!(:at) |> at() |> DateTime.truncate(:second)
      })

    q
  end

  describe "a turn that died" do
    test "is picked up with one line into the mouse's own pane", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      expect(Herdr, :prompt, fn "/s", "w1:p1", line ->
        assert line == Pickup.line()
        :ok
      end)

      {outcomes, _} = sweep(repo, @settled, seen)

      assert outcomes == [{m.id, :picked_up}]
      assert Storage.mouse(m.id).picked_up_at == at(@settled)
    end

    test "is picked up though the owl has asked something of it since", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      {:ok, _} =
        Storage.record_question(%{
          mouse_id: m.id,
          text: "Drop?",
          kind: "needs-decision",
          status: "sent",
          asked_by: "owl",
          asked_at: @quiet |> at() |> DateTime.truncate(:second)
        })

      expect(Herdr, :prompt, fn _, _, _ -> :ok end)
      assert {[{_, :picked_up}], _} = sweep(repo, @settled, seen)
    end

    test "is picked up when the pane reports idle rather than done", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m, status: "idle")

      expect(Herdr, :prompt, fn _, _, _ -> :ok end)

      assert {[{_, :picked_up}], _} = sweep(repo, @settled, seen)
    end

    test "herdr refusing the line leaves the branch exactly as it was", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      expect(Herdr, :prompt, fn _, _, _ -> {:error, :agent_blocked} end)

      assert {[{_, {:left, {:refused, :agent_blocked}}}], _} = sweep(repo, @settled, seen)
      assert Storage.mouse(m.id).picked_up_at == nil
    end
  end

  describe "a mouse on hold (ADR-0079)" do
    test "is never picked up: the person stopped it on purpose", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      {:ok, _} = Storage.hold(m.id)

      assert {[{_, {:left, :held}}], _} = sweep(repo, @settled, seen)
      assert %{picked_up_at: nil} = Storage.mouse(m.id)
    end
  end

  describe "a mouse with an answer it has not taken (ADR-0067)" do
    test "is left to the doorbell: its next turn never began", %{repo: repo} do
      m = mouse(repo, "feat-a")
      q = question(m, at: @before, kind: "needs-decision", status: "sent", text: "which?")
      {:ok, _} = Storage.answer(q.id, "SQLite")
      seen = died(repo, m)

      assert {[{_, {:left, :answer_not_taken}}], _} = sweep(repo, @settled, seen)
      assert %{picked_up_at: nil} = Storage.mouse(m.id)
    end
  end

  describe "a turn that did not die" do
    test "is left alone when its question reached the doorstep", %{repo: repo} do
      m = mouse(repo, "feat-a")
      {_, seen} = look(repo, @before, %{}, m, "idle")
      {_, seen} = look(repo, @worked, seen, m, "working")
      question(m, at: @quiet)
      {_, seen} = look(repo, @quiet, seen, m, "done")
      {_, seen} = look(repo, @between, seen, m, "done")

      assert {[{_, {:left, :finished}}], _} = sweep(repo, @settled, seen)
    end

    test "is left alone while its entry is still on the doorstep", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      {:ok, _} =
        Doorstep.leave(repo.checkout, %Entry{
          mouse_id: m.id,
          branch: m.branch,
          worktree_root: m.path,
          text: "all done",
          stamped_at: at(@quiet)
        })

      assert {[{_, {:left, :uncollected}}], _} = sweep(repo, @settled, seen)
    end

    test "is left alone while something of its waits on the person", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      question(m, kind: "needs-decision", status: "sent", at: -600)

      assert {[{_, {:left, :waiting}}], _} = sweep(repo, @settled, seen)
    end

    test "is left alone when the owl first saw the pane only after the entry landed",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      question(m, at: @worked)

      # herdr still calls the pane working for a moment after the hook has
      # written the entry, and a fresh owl has no memory to tell that from a
      # turn starting. It stamps nothing, so the finished turn is never read
      # as a died one.
      {_, seen} = look(repo, @worked, %{}, m, "working")
      {_, seen} = look(repo, @quiet, seen, m, "done")
      {_, seen} = look(repo, @between, seen, m, "done")

      assert {[{_, {:left, :never_worked}}], _} = sweep(repo, @settled, seen)
    end

    test "is left alone while work it started in the background is still out", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, backgrounded("bfz2zzaps", @worked) ++ [said("The suite is running.")])

      assert {[{_, {:left, :in_flight}}], _} = sweep(repo, @settled, seen)
    end

    test "is left alone after its stop was passed over, even once that work is half an hour old",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      transcript(
        m,
        backgrounded("bfz2zzaps", @worked - 3600) ++
          [said("The suite is running.", @worked - 3600)]
      )

      assert {[{_, {:left, :passed_over}}], _} = sweep(repo, @settled, seen)
    end

    test "nothing is picked up while an entry nobody can read is waiting", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      dir = Doorstep.path(repo.checkout)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "9999-whoever-xx.json"), "{not json")

      assert {[{_, {:left, :doorstep_unreadable}}], _} = sweep(repo, @settled, seen)
    end

    test "is left alone when no turn was ever seen", %{repo: repo} do
      m = mouse(repo, "feat-a")
      {_, seen} = look(repo, @between, %{}, m, "done")

      assert {[{_, {:left, :never_worked}}], _} = sweep(repo, @settled, seen)
    end
  end

  describe "a turn that died on an API error" do
    test "is picked up though work it started in the background is still out", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, backgrounded("bfz2zzaps", @worked) ++ [said("on it"), api_error()])

      expect(Herdr, :prompt, fn _, _, _ -> :ok end)
      assert {[{_, :picked_up}], _} = sweep(repo, @settled, seen)
    end

    test "is picked up the first sweep its pane is quiet, without the settling window",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      {_, seen} = look(repo, @before, %{}, m, "idle")
      {_, seen} = look(repo, @worked, seen, m, "working")
      {_, seen} = look(repo, @quiet, seen, m, "idle")
      transcript(m, [said("on it"), api_error(), turn_duration()])

      expect(Herdr, :prompt, fn "/s", "w1:p1", line ->
        assert line == Pickup.line()
        :ok
      end)

      assert {[{_, :picked_up}], _} = sweep(repo, @quiet, seen)
    end

    test "is picked up by an owl with no memory of the pane at all", %{repo: repo} do
      m = mouse(repo, "feat-a")
      {_, seen} = look(repo, @before, %{}, m, "idle")
      {_, _seen} = look(repo, @worked, seen, m, "working")
      transcript(m, [api_error()])
      herdr(panes(m, "idle"))

      expect(Herdr, :prompt, fn _, _, _ -> :ok end)

      assert {[{_, :picked_up}], _} = sweep(repo, @settled, %{})
    end

    test "still waits out the window when the transcript ends on an ordinary message",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      {_, seen} = look(repo, @before, %{}, m, "idle")
      {_, seen} = look(repo, @worked, seen, m, "working")
      {_, seen} = look(repo, @quiet, seen, m, "idle")
      transcript(m, [api_error(), said("carrying on"), turn_duration()])

      assert {[{_, {:left, :settling}}], _} = sweep(repo, @quiet, seen)
    end

    test "still waits out the window when there is no transcript", %{repo: repo} do
      m = mouse(repo, "feat-a")
      {_, seen} = look(repo, @before, %{}, m, "idle")
      {_, seen} = look(repo, @worked, seen, m, "working")
      {_, seen} = look(repo, @quiet, seen, m, "idle")

      assert {[{_, {:left, :settling}}], _} = sweep(repo, @quiet, seen)
    end

    test "a pane that is still working is a turn still running, whatever the transcript says",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      {_, seen} = look(repo, @before, %{}, m, "idle")
      {_, seen} = look(repo, @worked, seen, m, "working")
      transcript(m, [api_error()])

      assert {[{_, {:left, {:not_ready, "working"}}}], _} =
               look(repo, @quiet, seen, m, "working")
    end

    test "keeps every other rule: one attempt per died turn", %{repo: repo} do
      m = mouse(repo, "feat-a")
      {_, seen} = look(repo, @before, %{}, m, "idle")
      {_, seen} = look(repo, @worked, seen, m, "working")
      {_, seen} = look(repo, @quiet, seen, m, "idle")
      transcript(m, [api_error()])
      expect(Herdr, :prompt, fn _, _, _ -> :ok end)
      assert {[{_, :picked_up}], seen} = sweep(repo, @quiet, seen)

      assert {[{_, {:left, :already}}], _} = sweep(repo, @between, seen)
    end

    test "a mouse whose pickup also died on an API error is picked up again once its wait has passed",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, [said("on it"), api_error()])
      expect(Herdr, :prompt, 2, fn _, _, _ -> :ok end)
      {[{_, :picked_up}], seen} = sweep(repo, @settled, seen)

      {_, seen} = look(repo, @settled + 60, seen, m, "working")

      transcript(m, [
        said("on it"),
        api_error(),
        typed(Pickup.line(), @settled + 5),
        api_error("server_error", at: @settled + 30)
      ])

      {_, seen} = look(repo, @settled + 90, seen, m, "done")
      assert {[{_, {:left, {:retry_at, _}}}], seen} = sweep(repo, @settled + 100, seen)

      assert {[{_, :picked_up}], _} = sweep(repo, @settled + 120, seen)
    end

    test "an expired login is picked up again every ten minutes", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, [said("on it"), api_error("authentication_failed")])
      expect(Herdr, :prompt, 2, fn _, _, _ -> :ok end)
      {[{_, :picked_up}], seen} = sweep(repo, @settled, seen)

      transcript(m, [
        typed(Pickup.line(), @settled + 5),
        api_error("authentication_failed", at: @settled + 6)
      ])

      ten = DateTime.add(at(@settled), 600, :second)
      assert {[{_, {:left, {:retry_at, ^ten}}}], seen} = sweep(repo, @settled + 300, seen)
      assert {[{_, :picked_up}], _} = sweep(repo, @settled + 600, seen)
      assert %{stall_kind: "authentication_failed", pickups: 2} = Storage.mouse(m.id)
    end

    test "a rate limit waits for the reset Claude Code recorded, even the first time",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, [said("on it"), api_error("rate_limit", resets_at: @settled + 3600)])
      reset = DateTime.add(at(@settled), 3600, :second)

      assert {[{_, {:left, {:retry_at, ^reset}}}], seen} = sweep(repo, @settled, seen)

      expect(Herdr, :prompt, fn _, _, _ -> :ok end)
      assert {[{_, :picked_up}], _} = sweep(repo, @settled + 3600, seen)
    end

    test "an error that does not clear by itself is never picked up", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, [said("on it"), api_error("invalid_request")])

      assert {[{_, {:left, {:api_error, "invalid_request"}}}], _} = sweep(repo, @settled, seen)
      assert %{stall_kind: "invalid_request", retry_at: nil} = Storage.mouse(m.id)
    end

    test "a pickup whose line never reached the transcript is not retried", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, [said("on it"), api_error("server_error", at: @settled - 30)])
      expect(Herdr, :prompt, fn _, _, _ -> :ok end)
      {[{_, :picked_up}], seen} = sweep(repo, @settled, seen)

      assert {[{_, {:left, :already}}], _} = sweep(repo, @settled + 3600, seen)
    end

    test "a pickup line stamped in the future is no proof the pickup's own turn died",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, [said("on it"), api_error()])
      expect(Herdr, :prompt, fn _, _, _ -> :ok end)
      {[{_, :picked_up}], seen} = sweep(repo, @settled, seen)

      transcript(m, [typed(Pickup.line(), 10 ** 8), api_error("server_error", at: 10 ** 8 + 1)])

      assert {[{_, {:left, :already}}], _} = sweep(repo, @settled + 3600, seen)
    end

    test "an error the pickup's line drew within the same second is the pickup's own",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, [said("on it"), api_error("authentication_failed")])
      expect(Herdr, :prompt, fn _, _, _ -> :ok end)
      {[{_, :picked_up}], seen} = sweep(repo, @settled, seen)

      ms = fn n -> @settled |> at() |> DateTime.add(n, :millisecond) |> DateTime.to_iso8601() end

      transcript(m, [
        said("on it"),
        typed(Pickup.line(), @settled)
        |> JSON.decode!()
        |> Map.put("timestamp", ms.(250))
        |> JSON.encode!(),
        api_error("authentication_failed")
        |> JSON.decode!()
        |> Map.put("timestamp", ms.(600))
        |> JSON.encode!()
      ])

      ten = DateTime.add(at(@settled), 600, :second)
      assert {[{_, {:left, {:retry_at, ^ten}}}], _} = sweep(repo, @settled + 60, seen)
    end

    test "running /login in the mouse's own pane does not end its retries", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, [said("on it"), api_error("authentication_failed")])
      expect(Herdr, :prompt, 2, fn _, _, _ -> :ok end)
      {[{_, :picked_up}], seen} = sweep(repo, @settled, seen)

      transcript(m, [
        typed(Pickup.line(), @settled + 1),
        api_error("authentication_failed", at: @settled + 2),
        typed(
          "<command-name>/login</command-name>\n<command-message>login</command-message>",
          @settled + 100
        ),
        typed("<local-command-stdout>Login successful</local-command-stdout>", @settled + 101)
      ])

      assert {[{_, :picked_up}], _} = sweep(repo, @settled + 600, seen)
    end

    test "a mouse that stops retrying no longer says it waits out an error", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, [said("on it"), api_error()])
      expect(Herdr, :prompt, fn _, _, _ -> :ok end)
      {[{_, :picked_up}], seen} = sweep(repo, @settled, seen)
      assert Map.has_key?(Storage.stalls(), m.id)

      transcript(m, [typed(Pickup.line(), @settled + 5), said("crashed mid-turn")])

      assert {[{_, {:left, :already}}], _} = sweep(repo, @settled + 3600, seen)
      assert Storage.stalls() == %{}
    end

    test "the run, and whether the person was told of it, outlast the pickup's own turn",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, [said("on it"), api_error("authentication_failed")])
      expect(Herdr, :prompt, fn _, _, _ -> :ok end)
      {[{_, :picked_up}], seen} = sweep(repo, @settled, seen)
      Storage.set_stall_hooted(m.id, at(@settled))
      began = Storage.mouse(m.id).stalled_at

      transcript(m, [typed(Pickup.line(), @settled + 5)])
      {_, seen} = look(repo, @settled + 30, seen, m, "working")

      transcript(m, [
        typed(Pickup.line(), @settled + 5),
        api_error("authentication_failed", at: @settled + 40)
      ])

      {_, _} = look(repo, @settled + 60, seen, m, "done")
      assert %{stalled_at: ^began, stall_hooted_at: %DateTime{}} = Storage.mouse(m.id)
      assert Storage.untold_stalls() == []
    end

    test "an expired login partway through a told run is told too: only the person can fix it",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      Storage.set_stall(m.id, %{kind: "server_error", retry_at: at(0), failed: 3}, at(0))
      Storage.set_stall_hooted(m.id, at(0))

      Storage.set_stall(
        m.id,
        %{kind: "authentication_failed", retry_at: at(600), failed: 4},
        at(60)
      )

      assert [%{mouse_id: "m-feat-a"}] = Storage.untold_stalls()
    end

    test "a new run counts no failures from the run before it", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      Storage.set_picked_up(m.id, at(@before), 5)
      question(m, at: @before + 10)
      transcript(m, [said("next"), api_error()])
      stub(Herdr, :read_screen, fn _, _ -> {:ok, screen("box-holds-a-draft")} end)

      assert {[{_, {:left, :typing}}], _} = sweep(repo, @settled, seen)
      assert %{stall_failed: 0} = Storage.mouse(m.id)
    end

    test "a finished turn starts the count of pickups over", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, [said("on it"), api_error()])
      expect(Herdr, :prompt, 2, fn _, _, _ -> :ok end)
      {[{_, :picked_up}], seen} = sweep(repo, @settled, seen)
      assert %{pickups: 1} = Storage.mouse(m.id)

      {_, seen} = look(repo, @settled + 60, seen, m, "working")
      question(m, at: @settled + 90)
      {_, seen} = look(repo, @settled + 120, seen, m, "done")
      {_, seen} = look(repo, @settled + 180, seen, m, "working")
      transcript(m, [said("next"), api_error("server_error", at: @settled + 200)])

      assert {[{_, :picked_up}], _} = look(repo, @settled + 240, seen, m, "done")
      assert %{pickups: 1} = Storage.mouse(m.id)
    end

    test "a pane the owl may not type into records no stall, so nobody is told it carries on",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      transcript(m, [said("on it"), api_error("authentication_failed")])

      assert {[{_, {:left, :main_session}}], _} = sweep(repo, @settled, seen, main_pane: "w1:p1")
      assert Storage.untold_stalls() == []
    end

    test "keeps every other rule: the main session's pane is never typed into", %{repo: repo} do
      m = mouse(repo, "feat-a")
      {_, seen} = look(repo, @before, %{}, m, "idle")
      {_, seen} = look(repo, @worked, seen, m, "working")
      {_, seen} = look(repo, @quiet, seen, m, "idle")
      transcript(m, [api_error()])

      assert {[{_, {:left, :main_session}}], _} = sweep(repo, @quiet, seen, main_pane: "w1:p1")
    end

    test "keeps every other rule: herdr has to name the folder", %{repo: repo} do
      m = mouse(repo, "feat-a")
      {_, seen} = look(repo, @before, %{}, m, "idle")
      {_, seen} = look(repo, @worked, seen, m, "working")
      {_, seen} = look(repo, @quiet, seen, m, "idle")
      transcript(m, [api_error()])
      Process.put(:worktrees, [])

      assert {[{_, {:left, :not_our_worktree}}], _} = sweep(repo, @quiet, seen)
    end
  end

  describe "what herdr says about the pane" do
    test "a working pane is a turn still running", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      herdr(panes(m, "working"))

      assert {[{_, {:left, {:not_ready, "working"}}}], _} = sweep(repo, @settled, seen)
    end

    test "a pane herdr cannot classify is never permission", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m, status: "unknown")

      assert {[{_, {:left, {:not_ready, "unknown"}}}], _} = sweep(repo, @settled, seen)
    end

    test "a pane running something other than Claude is nothing to type into", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m, agent: "codex")

      assert {[{_, {:left, :no_claude}}], _} = sweep(repo, @settled, seen)
    end

    test "no pane at all is a dead mouse, not a dead turn", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      herdr([])

      assert {[{_, {:left, :no_pane}}], _} = sweep(repo, @settled, seen)
    end

    test "two panes in one worktree are nobody's pane to type into", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      herdr(panes(m, "done") ++ panes(m, "done", pane_id: "w1:p2"))

      assert {[{_, {:left, :many_panes}}], _} = sweep(repo, @settled, seen)
    end

    test "an ordinary sweep asks herdr nothing of its own", %{repo: repo} do
      m = mouse(repo, "feat-a")
      stub(Herdr, :worktrees, fn _, _ -> flunk("herdr was asked with nothing to pick up") end)
      {_, seen} = look(repo, @before, %{}, m, "idle")

      assert {[{_, {:left, :never_worked}}], _} = sweep(repo, @worked, seen)
    end

    test "a herdr that will not answer judges nothing and restarts every clock", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      assert {[], %{}} = sweep(repo, @settled, seen, panes: {:error, :closed})
    end
  end

  describe "the settling window" do
    test "a pane that has only just gone quiet is left to settle", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      assert {[{_, {:left, :settling}}], _} = sweep(repo, @quiet + 30, seen)
    end

    test "a pane that worked again starts the window over", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      {_, seen} = look(repo, @settled, seen, m, "working")
      {_, seen} = look(repo, @settled + 60, seen, m, "done")

      assert {[{_, {:left, :settling}}], _} = sweep(repo, @settled + 120, seen)
    end

    test "a sweep with no memory of the pane waits a window out first", %{repo: repo} do
      m = mouse(repo, "feat-a")
      _ = died(repo, m)

      {outcomes, seen} = look(repo, @settled, %{}, m, "done")
      assert [{_, {:left, :settling}}] = outcomes

      {_, seen} = look(repo, @settled + 60, seen, m, "done")

      expect(Herdr, :prompt, fn _, _, _ -> :ok end)
      assert {[{_, :picked_up}], _} = sweep(repo, @settled + 180, seen)
    end

    test "a gap the owl slept through is not two sweeps", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      woke = @settled + 8 * 3600

      assert {[{_, {:left, :settling}}], seen} =
               sweep(repo, woke, seen, last_sweep_at: at(@between))

      expect(Herdr, :prompt, fn _, _, _ -> :ok end)

      {_, seen} = look(repo, woke + 60, seen, m, "done")
      assert {[{_, :picked_up}], _} = sweep(repo, woke + 180, seen)
    end
  end

  describe "one attempt, never a loop" do
    test "a nudged turn that dies too is left as a stuck branch", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      expect(Herdr, :prompt, fn _, _, _ -> :ok end)
      {[{_, :picked_up}], seen} = sweep(repo, @settled, seen)

      {_, seen} = look(repo, @settled + 60, seen, m, "working")
      {_, seen} = look(repo, @settled + 120, seen, m, "done")
      {_, seen} = look(repo, @settled + 180, seen, m, "done")

      assert {[{_, {:left, :already}}], _} = sweep(repo, @settled + 240, seen)
    end

    test "a turn that finishes after a pickup earns the branch another one", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      expect(Herdr, :prompt, 2, fn _, _, _ -> :ok end)
      {[{_, :picked_up}], seen} = sweep(repo, @settled, seen)

      {_, seen} = look(repo, @settled + 60, seen, m, "working")
      question(m, at: @settled + 90)
      {_, seen} = look(repo, @settled + 120, seen, m, "done")
      {_, seen} = look(repo, @settled + 180, seen, m, "working")
      {_, seen} = look(repo, @settled + 240, seen, m, "done")
      {_, seen} = look(repo, @settled + 300, seen, m, "done")

      assert {[{_, :picked_up}], _} = sweep(repo, @settled + 360, seen)
    end
  end

  describe "the person's own half-typed line" do
    test "holds the pickup, exactly as it holds a delivery", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      stub(Herdr, :read_screen, fn _, _ -> {:ok, screen("box-holds-a-draft")} end)

      assert {[{_, {:left, :typing}}], _} = sweep(repo, @settled, seen)
      assert Storage.mouse(m.id).picked_up_at == nil
    end

    test "an empty box is no draft", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      stub(Herdr, :read_screen, fn _, _ ->
        {:ok, screen("main-session-empty-box-under-a-past-message")}
      end)

      expect(Herdr, :prompt, fn _, _, _ -> :ok end)

      assert {[{_, :picked_up}], _} = sweep(repo, @settled, seen)
    end

    test "Claude Code's faint suggestion in an empty box is no draft", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      stub(Herdr, :read_screen, fn _, _ ->
        {:ok, styled("suggestion-in-an-empty-box")}
      end)

      expect(Herdr, :prompt, fn _, _, _ -> :ok end)

      assert {[{_, :picked_up}], _} = sweep(repo, @settled, seen)
    end

    test "a screen with no box on it holds, exactly as it holds a delivery", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      stub(Herdr, :read_screen, fn _, _ -> {:ok, screen("box-scrolled-off-screen")} end)

      assert {[{_, {:left, :no_box}}], _} = sweep(repo, @settled, seen)
      assert Storage.mouse(m.id).picked_up_at == nil
    end
  end

  describe "a mouse the owl has no business in" do
    test "a path herdr does not call a worktree of this checkout is never typed into",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      Process.put(:worktrees, [])

      assert {[{_, {:left, :not_our_worktree}}], _} = sweep(repo, @settled, seen)
      assert Storage.mouse(m.id).picked_up_at == nil
    end

    test "the pane the person works in is never typed into, whatever a record says",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)

      assert {[{_, {:left, :main_session}}], _} =
               sweep(repo, @settled, seen, main_pane: "w1:p1")
    end

    test "a herdr that will not name this checkout's worktrees types nothing",
         %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      stub(Herdr, :worktrees, fn _, _ -> {:error, :closed} end)

      assert {[{_, {:left, :no_herdr}}], _} = sweep(repo, @settled, seen)
    end

    test "a removed record is never picked up", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      {:ok, _} = Storage.mark_removed(m.id)

      assert {[], _} = sweep(repo, @settled, seen)
    end

    test "a dead record is never picked up", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      {:ok, _} = Storage.mark_dead(m.id)

      assert {[], _} = sweep(repo, @settled, seen)
    end

    test "a worktree that is gone is never picked up", %{repo: repo} do
      m = mouse(repo, "feat-a")
      seen = died(repo, m)
      File.rm_rf!(m.path)

      assert {[{_, {:left, :gone}}], _} = sweep(repo, @settled, seen)
    end
  end

  @screens Path.expand("../support/screens", __DIR__)

  defp screen(name), do: File.read!(Path.join(@screens, name <> ".txt"))
  defp styled(name), do: File.read!(Path.join(@screens, name <> ".ansi"))
end
