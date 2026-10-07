defmodule Whiska.Herdr do
  @moduledoc """
  Talking to herdr — the one genuine external boundary this system has.

  Mice are herdr panes rather than processes Whiska owns (ADR-0020), so
  everything the owl knows about a mouse's liveness and idleness comes through
  here, in both directions: asking (`list_panes/1`) and being told
  (`subscribe/3`). ADR-0031 confines mocking to exactly this behaviour: the real
  implementation is `Whiska.Herdr.Socket`, tests use a `Mox` fake, and
  everything downstream — collection, classification — is plain code.

  The module in use is read from the `:herdr` application key.
  """

  @typedoc """
  What the owl needs to know about a pane. Everything else herdr sends is
  dropped.

  `title` is herdr's `terminal_title_stripped`, which for a Claude Code pane is
  the short summary the agent keeps of what it is working on — the mouse's topic,
  and the first thing the board says about it (ADR-0051's addendum of
  2026-10-02). It is somebody else's free text: it can be empty, it can be a
  shell command in a pane running one, and in some panes it still carries the
  agent's status glyph on the front.

  `scroll_offset` is how many rows above the bottom the viewport is sitting —
  `0` when the pane is showing the live end of its output, and `nil` when herdr
  did not say. It is what tells a screen with no prompt box on it apart from a
  person who has simply scrolled up past one (ADR-0068).
  """
  @type pane :: %{
          pane_id: String.t(),
          workspace_id: String.t() | nil,
          cwd: String.t() | nil,
          agent: String.t() | nil,
          agent_status: String.t(),
          title: String.t() | nil,
          session: String.t() | nil,
          scroll_offset: non_neg_integer() | nil
        }

  @typedoc """
  A linked worktree herdr knows about, and the workspace it is open in.

  `workspace_id` is `nil` when no workspace is open on it — the mouse's pane is
  already gone, and the worktree is git's alone to remove.
  """
  @type worktree :: %{
          path: String.t(),
          branch: String.t() | nil,
          workspace_id: String.t() | nil
        }

  @typedoc """
  A desktop notification, in herdr's own terms. `sound` is one of herdr's three
  — `:none`, `:done` (its finished sound) and `:request` (its needs-attention
  one).
  """
  @type notification :: %{title: String.t(), body: String.t(), sound: :none | :done | :request}

  @typedoc "One subscription, in herdr's own terms: `%{type: \"pane.closed\"}`."
  @type subscription :: %{required(:type) => String.t(), optional(:pane_id) => String.t()}

  @doc "Every pane herdr currently has."
  @callback list_panes(socket :: Path.t()) :: {:ok, [pane()]} | {:error, term()}

  @doc "One pane, by id — the fresh word on its agent and status, for the delivery gate."
  @callback pane(socket :: Path.t(), pane_id :: String.t()) :: {:ok, pane()} | {:error, term()}

  @doc """
  The visible screen of a pane, with its style escapes kept (`--format ansi`).

  Only the delivery gate uses this, and only for the main session's prompt box
  (ADR-0047): herdr has no input or keystroke signal, so whether the person is
  mid-sentence can be read from the screen or not at all. What the text means
  is `Whiska.Delivery.Draft`'s job, not this boundary's.
  """
  @callback read_screen(socket :: Path.t(), pane_id :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Type `text` into the agent in a pane and submit it — how a question reaches
  the main session and how an answer reaches a mouse (ADR-0020). herdr refuses
  when the agent sits at a dialog (`agent_blocked`) or when there is no agent
  (`agent_not_found`); the error carries herdr's own code.
  """
  @callback prompt(socket :: Path.t(), pane_id :: String.t(), text :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Type a command at a pane's shell prompt and run it — how `whiska start`
  starts Claude Code in the pane it has just recorded (ADR-0066).

  The only call here that puts text anywhere but into an agent, and it is the
  person's own command landing in the person's own pane, at the moment they
  asked for it. A pane with something already running in it keeps the text
  until its prompt comes back, which is what makes it work at all: `whiska
  start` is itself the thing running there.
  """
  @callback run_command(socket :: Path.t(), pane_id :: String.t(), command :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Bring a pane into view — the person's screen moves to it, in whichever
  workspace and tab it lives (ADR-0043).

  The one call here that acts on the person rather than on a mouse. herdr
  refuses with its own code when the pane is gone; the error carries it.
  """
  @callback focus(socket :: Path.t(), pane_id :: String.t()) :: :ok | {:error, term()}

  @typedoc """
  What herdr did with a notification. It decides from the person's own
  `[ui.toast]` and `[ui.sound]` settings, and says outright whether it drew
  anything — `{:not_shown, "disabled"}` when popups are turned off, carrying
  herdr's own reason string.
  """
  @type notify_result :: {:ok, :shown} | {:ok, {:not_shown, String.t()}} | {:error, term()}

  @doc """
  Raise a desktop notification — the hoot that goes out with a delivered line
  (ADR-0062).

  The only call here that is not about a pane, and the only one whose answer
  says what the person saw rather than what a pane is doing: a delivery ignores
  it, and `whiska doctor` probes with it (ADR-0038).
  """
  @callback notify(socket :: Path.t(), notification :: notification()) :: notify_result()

  @doc """
  Open a subscription and stream its events to `listener`.

  Returns the pid of the process holding the connection. Each event arrives at
  the listener as `{:herdr_event, name, data}` — `name` is herdr's event name
  exactly as streamed and `data` its payload, string-keyed. herdr 0.8.2 names a
  global event by its event type (`"pane_closed"`, `"pane_exited"`,
  `"pane_agent_detected"`) but a per-pane one by its subscription type
  (`"pane.agent_status_changed"`, with a dot); nothing is normalised here, so
  the listener has to accept both. The process is linked to the listener and exits normally when
  the connection drops, after sending `{:herdr_subscription_lost, reason}`, so
  the listener can resubscribe.
  """
  @callback subscribe(socket :: Path.t(), [subscription()], listener :: pid()) ::
              {:ok, pid()} | {:error, term()}

  @doc """
  The workspace open on a checkout itself — its own entry in herdr's worktree
  list, not one of its linked worktrees. `nil` when none is open there.
  """
  @callback main_workspace(socket :: Path.t(), checkout :: Path.t()) ::
              {:ok, String.t() | nil} | {:error, term()}

  @doc "The linked worktrees of one checkout, each with the workspace it is open in."
  @callback worktrees(socket :: Path.t(), checkout :: Path.t()) ::
              {:ok, [worktree()]} | {:error, term()}

  @doc """
  Open an existing worktree as a herdr workspace, and bring it into view.

  Starts no session in it: the workspace opens on a shell, because a second
  Claude Code session in one worktree is what ADR-0023 forbids. Only `whiska
  open` asks, and only because the person did.
  """
  @callback open_worktree(socket :: Path.t(), path :: Path.t()) :: :ok | {:error, term()}

  @doc """
  Remove a worktree and close the workspace it is open in, in one call.

  Never forced: herdr refusing a worktree with work in it is the refusal
  cleanup wants (ADR-0061), and the owl has no way to ask again harder.
  """
  @callback remove_worktree(socket :: Path.t(), workspace_id :: String.t()) ::
              :ok | {:error, term()}

  @doc "The implementation in use."
  @spec impl() :: module()
  def impl, do: Application.get_env(:whiska, :herdr, Whiska.Herdr.Socket)

  @doc "herdr's socket, from the environment herdr sets in every pane it runs."
  @spec socket_path() :: Path.t() | nil
  def socket_path, do: System.get_env("HERDR_SOCKET_PATH")

  @doc """
  herdr's socket for anything that needs to talk to herdr now: the variable
  when it is set, and otherwise herdr's fixed default (ADR-0040).

  The fallback is not only the supervised owl's. A hotkey command runs with no
  shell environment at all, so a hotkey running `whiska jump` sees exactly what
  the supervised owl sees: nothing. The variable still wins where it is set — a
  named herdr session's socket lives elsewhere.

  `{:error, {:no_socket, default}}` when nothing set the variable and there is
  no socket at the default path either. That is a different thing to say than
  "the variable is not set": the variable is not how anyone normally finds
  herdr, and the honest reading is that herdr is not running.
  """
  @spec socket(%{optional(String.t()) => String.t()}) ::
          {:ok, Path.t()} | {:error, {:no_socket, Path.t()}}
  def socket(env \\ System.get_env()) do
    case env["HERDR_SOCKET_PATH"] do
      path when is_binary(path) and path != "" ->
        {:ok, path}

      _unset ->
        default = default_socket_path(env)
        if File.exists?(default), do: {:ok, default}, else: {:error, {:no_socket, default}}
    end
  end

  @doc """
  Where herdr puts its socket when nothing says otherwise: `herdr.sock` in
  its default session directory, `~/.config/herdr/`. Checked against herdr
  0.8.2: the path is fixed per session and recreated there on every restart,
  so an owl started by launchd or systemd, with no pane's environment to
  inherit, can still find it. A named herdr session lives elsewhere; the job
  carries `HERDR_SOCKET_PATH` for that case and it wins.
  """
  @spec default_socket_path(%{optional(String.t()) => String.t()}) :: Path.t()
  def default_socket_path(env \\ System.get_env()) do
    home = env["HOME"] || System.user_home!()
    Path.join(home, ".config/herdr/herdr.sock")
  end

  @doc """
  herdr's own config file: `HERDR_CONFIG_PATH` when it is set, else
  `~/.config/herdr/config.toml`.

  The person's file, and machine-global. Whiska reads it — `whiska doctor`
  looks for the tab bar entry that draws the owl's line (ADR-0048) — and never
  writes it.
  """
  @spec config_path(%{optional(String.t()) => String.t()}) :: Path.t()
  def config_path(env \\ System.get_env()) do
    case env["HERDR_CONFIG_PATH"] do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        Path.join(env["HOME"] || System.user_home!(), ".config/herdr/config.toml")
    end
  end
end
