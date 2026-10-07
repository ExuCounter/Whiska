defmodule Whiska.Herdr.SocketTest do
  @moduledoc """
  The real herdr client, exercised against a fake herdr server speaking the
  same wire protocol: newline-delimited JSON over a Unix socket, one request per
  connection, and a subscription connection that stays open and streams events.
  """
  use ExUnit.Case, async: true

  alias Whiska.Herdr.Socket

  # A tiny herdr stand-in. Accepts one connection at a time, answers with the
  # canned reply for the method it sees, and — for events.subscribe — keeps the
  # connection open and pushes whatever the test hands it.
  defp start_fake do
    dir = Path.join(System.tmp_dir!(), "whiska-hs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "h.sock")
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, path}])

    test = self()

    fake = spawn_link(fn -> accept_loop(listener, test) end)
    {path, fake}
  end

  defp accept_loop(listener, test) do
    {:ok, sock} = :gen_tcp.accept(listener)
    {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
    request = JSON.decode!(line)
    send(test, {:fake_got, request})

    case request do
      %{"method" => "events.subscribe", "id" => id} ->
        :gen_tcp.send(
          sock,
          JSON.encode!(%{"id" => id, "result" => %{"type" => "subscription_started"}}) <> "\n"
        )

        stream(sock, test)

      %{"id" => id} ->
        receive do
          {:fake_reply, result} ->
            :gen_tcp.send(sock, JSON.encode!(%{"id" => id, "result" => result}) <> "\n")

          {:fake_error, error} ->
            :gen_tcp.send(sock, JSON.encode!(%{"id" => id, "error" => error}) <> "\n")
        after
          1_000 -> :ok
        end

        :gen_tcp.close(sock)
    end

    accept_loop(listener, test)
  end

  defp stream(sock, test) do
    receive do
      {:fake_push, event} ->
        :gen_tcp.send(sock, JSON.encode!(event) <> "\n")
        stream(sock, test)

      :fake_drop ->
        :gen_tcp.close(sock)
    end
  end

  describe "list_panes/1" do
    test "asks pane.list and returns the panes" do
      {path, fake} = start_fake()

      send(
        fake,
        {:fake_reply,
         %{
           "type" => "pane_list",
           "panes" => [
             %{
               "pane_id" => "w1:p1",
               "cwd" => "/a",
               "workspace_id" => "w1",
               "agent" => "claude",
               "agent_status" => "idle",
               "terminal_title" => "\u2733 Order builder",
               "terminal_title_stripped" => "Order builder",
               "scroll" => %{"offset_from_bottom" => 12, "max_offset_from_bottom" => 400}
             },
             %{"pane_id" => "w1:p2", "cwd" => nil, "agent" => nil, "agent_status" => "unknown"}
           ]
         }}
      )

      assert {:ok, panes} = Socket.list_panes(path)
      assert_received {:fake_got, %{"method" => "pane.list", "params" => %{}}}

      assert panes == [
               %{
                 pane_id: "w1:p1",
                 workspace_id: "w1",
                 cwd: "/a",
                 agent: "claude",
                 agent_status: "idle",
                 title: "Order builder",
                 session: nil,
                 scroll_offset: 12
               },
               %{
                 pane_id: "w1:p2",
                 workspace_id: nil,
                 cwd: nil,
                 agent: nil,
                 agent_status: "unknown",
                 title: nil,
                 session: nil,
                 scroll_offset: nil
               }
             ]
    end

    test "reads a reply longer than any single socket buffer" do
      # A real herdr with fifty-odd panes answers pane.list with well over
      # 64 KB on one line. Caught live: `packet: :line` hands back a truncated
      # line past its buffer, which parsed as unexpected end of JSON.
      {path, fake} = start_fake()
      long_cwd = String.duplicate("/some/long/directory/name", 20)

      panes =
        for i <- 1..500,
            do: %{
              "pane_id" => "w#{i}:p1",
              "cwd" => long_cwd,
              "agent" => "claude",
              "agent_status" => "idle"
            }

      send(fake, {:fake_reply, %{"type" => "pane_list", "panes" => panes}})

      assert {:ok, got} = Socket.list_panes(path)
      assert length(got) == 500
      assert List.last(got).pane_id == "w500:p1"
    end

    test "reports a socket nobody is listening on" do
      assert {:error, _} = Socket.list_panes("/nonexistent/herdr.sock")
    end
  end

  describe "subscribe/3" do
    test "streams events to the listener as messages" do
      {path, fake} = start_fake()
      subs = [%{type: "pane.closed"}, %{type: "pane.agent_status_changed", pane_id: "w1:p1"}]

      assert {:ok, sub} = Socket.subscribe(path, subs, self())
      assert is_pid(sub)

      assert_receive {:fake_got,
                      %{"method" => "events.subscribe", "params" => %{"subscriptions" => got}}}

      assert got == [
               %{"type" => "pane.closed"},
               %{"type" => "pane.agent_status_changed", "pane_id" => "w1:p1"}
             ]

      send(fake, {:fake_push, %{"event" => "pane_closed", "data" => %{"pane_id" => "w1:p1"}}})
      assert_receive {:herdr_event, "pane_closed", %{"pane_id" => "w1:p1"}}
    end

    test "the subscription process dies when herdr drops the connection" do
      {path, fake} = start_fake()
      {:ok, sub} = Socket.subscribe(path, [%{type: "pane.closed"}], self())
      ref = Process.monitor(sub)
      assert_receive {:fake_got, _}

      send(fake, :fake_drop)
      assert_receive {:herdr_subscription_lost, :closed}
      assert_receive {:DOWN, ^ref, :process, ^sub, :normal}
    end

    test "fails when there is no herdr" do
      assert {:error, _} =
               Socket.subscribe("/nonexistent/herdr.sock", [%{type: "pane.closed"}], self())
    end
  end

  describe "pane/2" do
    test "asks pane.get and returns that one pane" do
      {path, fake} = start_fake()

      send(
        fake,
        {:fake_reply,
         %{
           "type" => "pane_info",
           "pane" => %{
             "pane_id" => "w1:p2",
             "cwd" => "/main",
             "agent" => "claude",
             "agent_status" => "idle",
             "focused" => true,
             "scroll" => %{"offset_from_bottom" => 0, "max_offset_from_bottom" => 0}
           }
         }}
      )

      assert {:ok, pane} = Socket.pane(path, "w1:p2")
      assert_received {:fake_got, %{"method" => "pane.get", "params" => %{"pane_id" => "w1:p2"}}}

      assert pane == %{
               pane_id: "w1:p2",
               workspace_id: nil,
               cwd: "/main",
               agent: "claude",
               agent_status: "idle",
               title: nil,
               session: nil,
               scroll_offset: 0
             }
    end

    test "the agent's own session id comes through — the doctor finds the transcript by it" do
      {path, fake} = start_fake()

      send(
        fake,
        {:fake_reply,
         %{
           "type" => "pane_info",
           "pane" => %{
             "pane_id" => "w1:p2",
             "agent" => "claude",
             "agent_session" => %{
               "agent" => "claude",
               "kind" => "id",
               "value" => "bea77b20-9a0e-444f-b49a-cc0f1ae493cb"
             }
           }
         }}
      )

      assert {:ok, %{session: "bea77b20-9a0e-444f-b49a-cc0f1ae493cb"}} =
               Socket.pane(path, "w1:p2")
    end

    test "a pane herdr does not know is an error carrying herdr's code" do
      {path, fake} = start_fake()
      send(fake, {:fake_error, %{"code" => "not_found", "message" => "no such pane"}})

      assert {:error, {:herdr, %{"code" => "not_found"}}} = Socket.pane(path, "w9:p9")
    end
  end

  describe "read_screen/2" do
    # The styling is the only thing that tells Claude Code's dim suggestion
    # from the person's own words (ADR-0068), so herdr must not strip it.
    test "asks pane.read for the visible screen with its styling kept" do
      {path, fake} = start_fake()
      screen = "❯ \e[0m\e[2mpush and open a PR\e[0m\r\n"
      send(fake, {:fake_reply, %{"type" => "pane_read", "read" => %{"text" => screen}}})

      assert {:ok, ^screen} = Socket.read_screen(path, "w1:p2")

      assert_received {:fake_got,
                       %{
                         "method" => "pane.read",
                         "params" => %{
                           "pane_id" => "w1:p2",
                           "source" => "visible",
                           "format" => "ansi",
                           "strip_ansi" => false
                         }
                       }}
    end
  end

  describe "prompt/3" do
    test "asks agent.prompt with the pane as target and the text" do
      {path, fake} = start_fake()
      send(fake, {:fake_reply, %{"type" => "agent_prompted"}})

      assert :ok = Socket.prompt(path, "w1:p2", "hello there")

      assert_received {:fake_got,
                       %{
                         "method" => "agent.prompt",
                         "params" => %{"target" => "w1:p2", "text" => "hello there"}
                       }}
    end

    test "herdr refusing — an agent at a dialog, or none — is an error with the code" do
      {path, fake} = start_fake()
      send(fake, {:fake_error, %{"code" => "agent_blocked", "message" => "at a dialog"}})

      assert {:error, {:herdr, %{"code" => "agent_blocked"}}} = Socket.prompt(path, "w1:p2", "x")
    end

    test "fails when there is no herdr" do
      assert {:error, _} = Socket.prompt("/nonexistent/herdr.sock", "w1:p2", "x")
    end
  end

  describe "focus/2" do
    test "asks pane.focus with the pane id (ADR-0043)" do
      {path, fake} = start_fake()
      send(fake, {:fake_reply, %{"type" => "pane_focused"}})

      assert :ok = Socket.focus(path, "w1:p2")

      assert_received {:fake_got,
                       %{"method" => "pane.focus", "params" => %{"pane_id" => "w1:p2"}}}
    end

    test "a pane herdr no longer has is an error with the code" do
      {path, fake} = start_fake()
      send(fake, {:fake_error, %{"code" => "pane_not_found", "message" => "gone"}})

      assert {:error, {:herdr, %{"code" => "pane_not_found"}}} = Socket.focus(path, "w9:p9")
    end

    test "fails when there is no herdr" do
      assert {:error, _} = Socket.focus("/nonexistent/herdr.sock", "w1:p2")
    end
  end

  describe "worktrees/2" do
    test "asks worktree.list for one checkout and keeps the linked worktrees" do
      {path, fake} = start_fake()

      send(
        fake,
        {:fake_reply,
         %{
           "type" => "worktree_list",
           "worktrees" => [
             %{
               "path" => "/main",
               "label" => "main",
               "branch" => "main",
               "is_bare" => false,
               "is_detached" => false,
               "is_prunable" => false,
               "is_linked_worktree" => false,
               "open_workspace_id" => "ws-main"
             },
             %{
               "path" => "/main/worktrees/feat-a",
               "label" => "feat-a",
               "branch" => "feat-a",
               "is_bare" => false,
               "is_detached" => false,
               "is_prunable" => false,
               "is_linked_worktree" => true,
               "open_workspace_id" => "ws-7"
             }
           ]
         }}
      )

      assert {:ok, worktrees} = Socket.worktrees(path, "/main")

      assert_received {:fake_got, %{"method" => "worktree.list", "params" => %{"cwd" => "/main"}}}

      assert worktrees == [
               %{path: "/main/worktrees/feat-a", branch: "feat-a", workspace_id: "ws-7"}
             ]
    end

    test "a worktree herdr has no workspace open for carries no id" do
      {path, fake} = start_fake()

      send(
        fake,
        {:fake_reply,
         %{
           "type" => "worktree_list",
           "worktrees" => [
             %{
               "path" => "/main/worktrees/feat-b",
               "label" => "feat-b",
               "branch" => "feat-b",
               "is_bare" => false,
               "is_detached" => false,
               "is_prunable" => false,
               "is_linked_worktree" => true,
               "open_workspace_id" => nil
             }
           ]
         }}
      )

      assert {:ok, [%{workspace_id: nil}]} = Socket.worktrees(path, "/main")
    end
  end

  describe "main_workspace/2" do
    test "asks worktree.list for one checkout and answers with its own entry's workspace" do
      {path, fake} = start_fake()

      send(
        fake,
        {:fake_reply,
         %{
           "type" => "worktree_list",
           "worktrees" => [
             %{
               "path" => "/main/worktrees/feat-a",
               "is_linked_worktree" => true,
               "open_workspace_id" => "ws-7"
             },
             %{"path" => "/main", "is_linked_worktree" => false, "open_workspace_id" => "ws-main"}
           ]
         }}
      )

      assert {:ok, "ws-main"} = Socket.main_workspace(path, "/main")
      assert_received {:fake_got, %{"method" => "worktree.list", "params" => %{"cwd" => "/main"}}}
    end

    test "no workspace open on the checkout is nil" do
      {path, fake} = start_fake()

      send(
        fake,
        {:fake_reply,
         %{
           "type" => "worktree_list",
           "worktrees" => [
             %{"path" => "/main", "is_linked_worktree" => false, "open_workspace_id" => nil}
           ]
         }}
      )

      assert {:ok, nil} = Socket.main_workspace(path, "/main")
    end

    test "a list with only linked worktrees has no workspace of the checkout's own" do
      {path, fake} = start_fake()

      send(
        fake,
        {:fake_reply,
         %{
           "type" => "worktree_list",
           "worktrees" => [
             %{
               "path" => "/main/worktrees/a",
               "is_linked_worktree" => true,
               "open_workspace_id" => "ws-7"
             }
           ]
         }}
      )

      assert {:ok, nil} = Socket.main_workspace(path, "/main")
    end
  end

  describe "remove_worktree/2" do
    test "asks worktree.remove for that workspace and never forces" do
      {path, fake} = start_fake()
      send(fake, {:fake_reply, %{"type" => "worktree_removed"}})

      assert :ok = Socket.remove_worktree(path, "ws-7")

      assert_received {:fake_got,
                       %{
                         "method" => "worktree.remove",
                         "params" => %{"workspace_id" => "ws-7", "force" => false}
                       }}
    end

    test "herdr refusing is an error carrying its code, never a retry with force" do
      {path, fake} = start_fake()
      send(fake, {:fake_error, %{"code" => "worktree_dirty", "message" => "uncommitted changes"}})

      assert {:error, {:herdr, %{"code" => "worktree_dirty"}}} =
               Socket.remove_worktree(path, "ws-7")
    end
  end

  # The shape herdr 0.9.3 answers `workspace.list` with, checked live on
  # 2026-10-07: `tokens` is there only once something reported one, and
  # `worktree` only for a workspace opened on a git checkout.
  defp raw_workspaces do
    [
      %{
        "workspace_id" => "w1",
        "number" => 1,
        "label" => "myrepo",
        "worktree" => %{"checkout_path" => "/main", "is_linked_worktree" => false}
      },
      %{
        "workspace_id" => "w7",
        "number" => 2,
        "label" => "feat/a",
        "tokens" => %{"whiska" => "🐭 #3 · waiting on you"},
        "worktree" => %{"checkout_path" => "/main/worktrees/feat/a", "is_linked_worktree" => true}
      },
      %{"workspace_id" => "w9", "number" => 3, "label" => "scratch"}
    ]
  end

  describe "version/1" do
    test "asks ping and answers herdr's version" do
      {path, fake} = start_fake()
      send(fake, {:fake_reply, %{"type" => "pong", "version" => "0.9.3", "protocol" => 22}})

      assert {:ok, "0.9.3"} = Socket.version(path)
      assert_received {:fake_got, %{"method" => "ping", "params" => %{}}}
    end
  end

  describe "workspaces/1" do
    test "asks workspace.list, in order, with the tokens herdr holds" do
      {path, fake} = start_fake()
      send(fake, {:fake_reply, %{"type" => "workspace_list", "workspaces" => raw_workspaces()}})

      assert {:ok, workspaces} = Socket.workspaces(path)
      assert_received {:fake_got, %{"method" => "workspace.list", "params" => %{}}}

      assert workspaces == [
               %{workspace_id: "w1", number: 1, path: "/main", linked?: false, tokens: %{}},
               %{
                 workspace_id: "w7",
                 number: 2,
                 path: "/main/worktrees/feat/a",
                 linked?: true,
                 tokens: %{"whiska" => "🐭 #3 · waiting on you"}
               },
               %{workspace_id: "w9", number: 3, path: nil, linked?: nil, tokens: %{}}
             ]
    end

    test "fails when there is no herdr" do
      assert {:error, _} = Socket.workspaces("/nonexistent/herdr.sock")
    end
  end

  describe "report_metadata/4" do
    test "asks workspace.report_metadata as whiska, a nil token clearing it" do
      {path, fake} = start_fake()
      send(fake, {:fake_reply, %{"type" => "ok"}})

      tokens = %{"whiska" => "◐ order builder", "whiska_q" => nil}
      assert :ok = Socket.report_metadata(path, "w7", tokens, 30_000)

      assert_received {:fake_got,
                       %{
                         "method" => "workspace.report_metadata",
                         "params" => %{
                           "workspace_id" => "w7",
                           "source" => "whiska",
                           "tokens" => %{"whiska" => "◐ order builder", "whiska_q" => nil},
                           "ttl_ms" => 30_000
                         }
                       }}
    end

    test "an older herdr that has no such method is an error carrying its code" do
      {path, fake} = start_fake()
      send(fake, {:fake_error, %{"code" => "unknown_method", "message" => "no such method"}})

      assert {:error, {:herdr, %{"code" => "unknown_method"}}} =
               Socket.report_metadata(path, "w7", %{"whiska" => "x"}, 30_000)
    end
  end

  describe "move_block/3" do
    test "asks workspace.move_block and answers the new order" do
      {path, fake} = start_fake()
      send(fake, {:fake_reply, %{"type" => "workspace_list", "workspaces" => raw_workspaces()}})

      assert {:ok, [%{workspace_id: "w1"}, %{workspace_id: "w7"}, %{workspace_id: "w9"}]} =
               Socket.move_block(path, ["w7", "w1"], "w9")

      assert_received {:fake_got,
                       %{
                         "method" => "workspace.move_block",
                         "params" => %{
                           "workspace_ids" => ["w7", "w1"],
                           "before_workspace_id" => "w9"
                         }
                       }}
    end

    test "no anchor leaves it out, which moves the block to the end" do
      {path, fake} = start_fake()
      send(fake, {:fake_reply, %{"type" => "workspace_list", "workspaces" => raw_workspaces()}})

      assert {:ok, _} = Socket.move_block(path, ["w7"], nil)

      assert_received {:fake_got,
                       %{
                         "method" => "workspace.move_block",
                         "params" => %{"workspace_ids" => ["w7"]} = params
                       }}

      refute Map.has_key?(params, "before_workspace_id")
    end

    test "herdr refusing an anchor inside the block is an error carrying its code" do
      {path, fake} = start_fake()
      send(fake, {:fake_error, %{"code" => "workspace_move_block_failed", "message" => "inside"}})

      assert {:error, {:herdr, %{"code" => "workspace_move_block_failed"}}} =
               Socket.move_block(path, ["w7"], "w7")
    end
  end
end
