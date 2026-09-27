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
               "agent" => "claude",
               "agent_status" => "idle"
             },
             %{"pane_id" => "w1:p2", "cwd" => nil, "agent" => nil, "agent_status" => "unknown"}
           ]
         }}
      )

      assert {:ok, panes} = Socket.list_panes(path)
      assert_received {:fake_got, %{"method" => "pane.list", "params" => %{}}}

      assert panes == [
               %{pane_id: "w1:p1", cwd: "/a", agent: "claude", agent_status: "idle"},
               %{pane_id: "w1:p2", cwd: nil, agent: nil, agent_status: "unknown"}
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
             "focused" => true
           }
         }}
      )

      assert {:ok, pane} = Socket.pane(path, "w1:p2")
      assert_received {:fake_got, %{"method" => "pane.get", "params" => %{"pane_id" => "w1:p2"}}}
      assert pane == %{pane_id: "w1:p2", cwd: "/main", agent: "claude", agent_status: "idle"}
    end

    test "a pane herdr does not know is an error carrying herdr's code" do
      {path, fake} = start_fake()
      send(fake, {:fake_error, %{"code" => "not_found", "message" => "no such pane"}})

      assert {:error, {:herdr, %{"code" => "not_found"}}} = Socket.pane(path, "w9:p9")
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
end
