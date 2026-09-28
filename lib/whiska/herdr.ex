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

  @typedoc "What the owl needs to know about a pane. Everything else herdr sends is dropped."
  @type pane :: %{
          pane_id: String.t(),
          cwd: String.t() | nil,
          agent: String.t() | nil,
          agent_status: String.t()
        }

  @typedoc "One subscription, in herdr's own terms: `%{type: \"pane.closed\"}`."
  @type subscription :: %{required(:type) => String.t(), optional(:pane_id) => String.t()}

  @doc "Every pane herdr currently has."
  @callback list_panes(socket :: Path.t()) :: {:ok, [pane()]} | {:error, term()}

  @doc "One pane, by id — the fresh word on its agent and status, for the delivery gate."
  @callback pane(socket :: Path.t(), pane_id :: String.t()) :: {:ok, pane()} | {:error, term()}

  @doc """
  Type `text` into the agent in a pane and submit it — how a question reaches
  the main session and how an answer reaches a mouse (ADR-0020). herdr refuses
  when the agent sits at a dialog (`agent_blocked`) or when there is no agent
  (`agent_not_found`); the error carries herdr's own code.
  """
  @callback prompt(socket :: Path.t(), pane_id :: String.t(), text :: String.t()) ::
              :ok | {:error, term()}

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

  @doc "The implementation in use."
  @spec impl() :: module()
  def impl, do: Application.get_env(:whiska, :herdr, Whiska.Herdr.Socket)

  @doc "herdr's socket, from the environment herdr sets in every pane it runs."
  @spec socket_path() :: Path.t() | nil
  def socket_path, do: System.get_env("HERDR_SOCKET_PATH")
end
