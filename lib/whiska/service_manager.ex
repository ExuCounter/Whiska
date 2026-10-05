defmodule Whiska.ServiceManager do
  @moduledoc """
  The platform's own service manager, which keeps the owl running: starts it
  at login and restarts it if it crashes (ADR-0040, ADR-next-the-owl-is-kept-by-the-platforms-service-manager).

  - macOS: launchd, through a user LaunchAgent — `Whiska.LaunchAgent`.
  - Linux: systemd, through a user unit — `Whiska.SystemdUnit`.

  `whiska owl install|uninstall|stop|start` and the doctor talk to whichever is
  in force through this behaviour, so the verbs mean the same thing on both.
  Both run the same wrapper, `~/.whiska/owl.sh`, which finds the binary and the
  Erlang runtime at every launch; neither manager hands a job a useful `PATH`.

  Every call a manager makes goes through a runner a test replaces, and a
  runner that raises — the program is not installed — answers as a failed
  call, never a crash: `whiska owl` asks the manager first, and must still
  start where there is none.
  """

  alias Whiska.Install

  @type paths :: %{job: Path.t(), wrapper: Path.t(), log: Path.t()}
  @type status :: %{loaded: boolean(), pid: pos_integer() | nil, last_exit_code: integer() | nil}

  @doc "The manager's own name, as in \"under launchd\"."
  @callback name() :: String.t()
  @doc "What the job is called, in the manager's words: the doctor's line names it."
  @callback noun() :: String.t()
  @doc "The job's label or unit name."
  @callback label() :: String.t()
  @doc "Where the job file, the wrapper and the log go on this machine."
  @callback paths() :: paths()
  @doc "Whether the manager can be used here at all, and why not when it cannot."
  @callback ready() :: :ok | {:error, String.t()}
  @doc "Write the wrapper and the job file. Safe to re-run."
  @callback install(paths(), %{optional(String.t()) => String.t()}) :: :ok | {:error, term()}
  @doc "Remove the wrapper and the job file. The log stays."
  @callback uninstall(paths()) :: :ok | {:error, :not_installed}
  @doc "Is the job file there? Says nothing about loaded."
  @callback installed?(paths()) :: boolean()
  @doc "Is the job loaded, and the owl running under it."
  @callback status() :: status()
  @doc "Hand the written job to the manager, replacing a loaded one, and start the owl."
  @callback load(paths(), status()) :: :ok | {:error, String.t()}
  @doc "Take the job away from the manager. A running owl stops with it."
  @callback unload() :: :ok | {:error, String.t()}
  @doc "Ask the owl to exit cleanly. The job stays, and returns when the manager next starts the user's session."
  @callback stop() :: :ok | {:error, String.t()}
  @doc "Start the owl now."
  @callback start() :: :ok | {:error, String.t()}
  @doc """
  Whether the owl outlives the person's last login session. systemd stops a
  user's services when they log out unless lingering is on; launchd has no
  such switch for a user agent, so it is `:not_applicable` there.
  """
  @callback linger() :: boolean() | :not_applicable

  @doc "The manager in force: the `:service_manager` setting, else this platform's."
  @spec impl() :: module()
  def impl, do: Application.get_env(:whiska, :service_manager) || for_os(:os.type())

  @doc "launchd on macOS; systemd everywhere else, which says so when it is not there."
  @spec for_os({atom(), atom()}) :: module()
  def for_os({:unix, :darwin}), do: Whiska.LaunchAgent
  def for_os(_other), do: Whiska.SystemdUnit

  @doc """
  Run a program found on `PATH`. One that is not there answers exit 127, the
  shell's own code for it, rather than raising.
  """
  @spec cmd(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def cmd(program, args) do
    case System.find_executable(program) do
      nil -> {"#{program}: not found", 127}
      path -> System.cmd(path, args, stderr_to_stdout: true)
    end
  end

  @doc """
  Call a runner. One that raises — a stand-in for the real program that is
  not installed — answers as a failed call with the reason as its output.
  """
  @spec call((list() -> {String.t(), non_neg_integer()}), list()) ::
          {String.t(), non_neg_integer()}
  def call(run, args) do
    run.(args)
  rescue
    e in ErlangError -> {"#{Exception.message(e)}", 127}
  end

  @doc "`:ok` for exit 0, else the trimmed output as the reason."
  @spec ok?({String.t(), non_neg_integer()}) :: :ok | {:error, String.t()}
  def ok?({_, 0}), do: :ok
  def ok?({out, _}), do: {:error, String.trim(out)}

  @doc "The user's home: the `:user_home` setting, else the real one."
  @spec user_home() :: Path.t()
  def user_home, do: Application.get_env(:whiska, :user_home) || System.user_home!()

  @doc "This user's uid: the `:uid` setting, else `id -u`."
  @spec uid() :: pos_integer()
  def uid do
    Application.get_env(:whiska, :uid) ||
      case System.cmd("id", ["-u"]) do
        {out, 0} -> out |> String.trim() |> String.to_integer()
      end
  end

  @doc """
  The installing shell's variables a job carries, when set: the manager
  passes the job almost no environment of its own, and the owl needs herdr's
  socket to hear about idle mice (a fallback exists in code).
  """
  @spec passthrough(%{optional(String.t()) => String.t()}) :: [{String.t(), String.t()}]
  def passthrough(env) do
    for name <- ~w(HERDR_SOCKET_PATH WHISKA_BIN WHISKA_ESCRIPT WHISKA_HOME),
        value = env[name],
        is_binary(value),
        value != "",
        do: {name, value}
  end

  @wrapper """
           #!/usr/bin/env bash
           # Whiska's owl, as launchd or systemd runs it (ADR-0040). Written by
           # `whiska owl install`; do not edit, it is overwritten on the next install.
           #
           # A service manager starts a job with almost no PATH, so the binary and
           # the Erlang runtime are resolved here, at every launch, exactly as the
           # hook shim resolves them - the same fragments, generated from the
           # same source. An Erlang upgrade needs no reinstall.

           """ <>
             Install.resolve_whiska() <>
             """
             if [ -z "$whiska_bin" ]; then
               echo "whiska: no whiska binary found (set WHISKA_BIN and run whiska owl install again, or install to ~/.local/bin)" >&2
               exit 1
             fi

             """ <>
             Install.resolve_escript() <>
             """
             # No arguments: the owl reopens every house in its record (ADR-0039).
             # exec, so the manager's pid for the job is the owl's own (ADR-0040).
             if [ -n "$escript_bin" ]; then
               exec "$escript_bin" "$whiska_bin" owl
             fi
             exec "$whiska_bin" owl
             """

  @doc "The wrapper script the manager runs."
  @spec wrapper() :: String.t()
  def wrapper, do: @wrapper

  @doc "Write `job_text` to the job file and the wrapper beside it. Safe to re-run."
  @spec write(paths(), String.t()) :: :ok | {:error, term()}
  def write(%{job: job, wrapper: wrapper}, job_text) do
    with :ok <- File.mkdir_p(Path.dirname(wrapper)),
         :ok <- File.write(wrapper, @wrapper),
         :ok <- File.chmod(wrapper, 0o755),
         :ok <- File.mkdir_p(Path.dirname(job)) do
      File.write(job, job_text)
    end
  end

  @doc "Remove the job file and the wrapper. The log stays."
  @spec remove(paths()) :: :ok | {:error, :not_installed}
  def remove(%{job: job, wrapper: wrapper}) do
    if File.exists?(job) do
      File.rm(job)
      File.rm(wrapper)
      :ok
    else
      {:error, :not_installed}
    end
  end
end
