defmodule Whiska.SystemdUnit do
  @moduledoc """
  The owl under systemd, on Linux (ADR-next-the-owl-is-kept-by-the-platforms-service-manager):
  one user unit, `whiska-owl.service`, that starts the owl at login and
  restarts it if it crashes. The same job `Whiska.LaunchAgent` is on macOS,
  through the same `Whiska.ServiceManager` verbs.

  Three files, all under the person's own home:

  - `~/.config/systemd/user/whiska-owl.service` — the unit. It runs the shared
    wrapper rather than the escript, for launchd's reason: systemd's user
    manager hands a service a bare `PATH` too. It runs the wrapper itself,
    through its `#!/usr/bin/env bash`, since NixOS and Guix have no `/bin/bash`.
  - `~/.whiska/owl.sh` — the wrapper, `Whiska.ServiceManager.wrapper/0`.
  - `~/.whiska/owl.log` — stdout and stderr, appended, as on macOS, so the
    doctor and the person look in one place on both.

  `Restart=on-failure` is launchd's `SuccessfulExit = false`: a crash is
  restarted and a clean exit is left alone. `RestartSec=10` is launchd's own
  throttle, and keeps a crash loop under systemd's start limit, so the unit
  keeps retrying as launchd's does instead of giving up after five.
  `whiska owl stop` is `systemctl --user stop`: the unit stays enabled and
  comes back on `whiska owl start`, or when systemd next starts this user's
  session — a fresh login once every session has ended, or a boot with
  lingering on.

  systemd stops a user's services when their last session ends unless
  lingering is on (`loginctl enable-linger`). That is a machine setting, so
  install never turns it on; it says how, and the doctor warns while it is off.

  Every call goes through a runner that tests replace — the `:systemd`
  setting, given the whole command line, program first. The real one is
  `run/1`. Where there is no systemd for this user (most containers, WSL
  without it), `ready/0` says so and the foreground owl still works.
  """

  @behaviour Whiska.ServiceManager

  alias Whiska.ServiceManager

  @unit "whiska-owl.service"

  @type runner :: ([String.t()] -> {String.t(), non_neg_integer()})

  @impl true
  def name, do: "systemd"

  @impl true
  def noun, do: "systemd unit"

  @impl true
  def label, do: @unit

  @doc "Where the three files go, given the user's home and the whiska home."
  @spec paths(Path.t(), Path.t()) :: ServiceManager.paths()
  def paths(user_home, whiska_home) do
    %{
      job: Path.join(user_home, ".config/systemd/user/#{@unit}"),
      wrapper: Path.join(whiska_home, "owl.sh"),
      log: Path.join(whiska_home, "owl.log")
    }
  end

  @impl true
  def paths, do: paths(ServiceManager.user_home(), Whiska.OpenHouses.home())

  @doc "The runner: the `:systemd` setting, else the real programs."
  @spec runner() :: runner()
  def runner, do: Application.get_env(:whiska, :systemd) || (&run/1)

  @doc "Run the real program named first in `argv`."
  @spec run([String.t()]) :: {String.t(), non_neg_integer()}
  def run([program | args]), do: ServiceManager.cmd(program, args)

  @doc """
  The unit. `env` is the installing shell's environment; the variables the
  owl needs are copied through, nothing else.

  Values are quoted for systemd: a path may hold a space, `%` starts one of
  systemd's specifiers, and `$` in `ExecStart` is a variable. A control
  character would end the line, and `install/2` refuses one before this runs.
  """
  @spec unit(ServiceManager.paths(), %{optional(String.t()) => String.t()}) :: String.t()
  def unit(%{wrapper: wrapper, log: log}, env) do
    environment =
      Enum.map_join(ServiceManager.passthrough(env), "", fn {k, v} ->
        "Environment=#{quote_value("#{k}=#{v}")}\n"
      end)

    """
    # Whiska's owl, as systemd runs it. Written by `whiska owl install`;
    # do not edit, it is overwritten on the next install.
    [Unit]
    Description=Whiska's owl

    [Service]
    ExecStart=#{quote_value(String.replace(wrapper, "$", "$$"))}
    Restart=on-failure
    RestartSec=10
    StandardOutput=append:#{specifiers(log)}
    StandardError=append:#{specifiers(log)}
    #{environment}
    [Install]
    WantedBy=default.target
    """
  end

  defp quote_value(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> specifiers()

    "\"#{escaped}\""
  end

  defp specifiers(value), do: String.replace(value, "%", "%%")

  @doc """
  Write the wrapper and the unit. Safe to re-run. A path or a value holding a
  control character is refused: systemd ends a line at a newline, a carriage
  return or a NUL, and reads an `append:` path with no unescaping, so no
  quoting can carry one.
  """
  @impl true
  def install(paths, env) do
    with :ok <- no_control_characters(paths, env) do
      ServiceManager.write(paths, unit(paths, env))
    end
  end

  defp no_control_characters(%{wrapper: wrapper, log: log}, env) do
    named =
      [{"the whiska home", wrapper}, {"the whiska home", log}] ++ ServiceManager.passthrough(env)

    case Enum.find(named, fn {_name, value} -> String.match?(value, ~r/[\x00-\x1f\x7f]/) end) do
      nil -> :ok
      {name, _value} -> {:error, {:control_character, name}}
    end
  end

  @doc """
  Remove the wrapper and the unit, and have systemd forget it. The log stays.
  The reload is best effort: the files are what uninstall promises.
  """
  @impl true
  def uninstall(paths) do
    with :ok <- ServiceManager.remove(paths) do
      systemctl(["daemon-reload"])
      :ok
    end
  end

  @impl true
  def installed?(%{job: unit}), do: File.exists?(unit)

  @doc "systemd is there for this user when its user manager answers at all."
  @impl true
  def ready do
    case systemctl(["show-environment"]) do
      {_, 0} ->
        :ok

      {out, _} ->
        {:error,
         "systemd is not running for this user here (#{String.trim(out)}), " <>
           "so nothing can keep the owl running"}
    end
  end

  @doc "Read the edited unit, enable it for every login, and start it now."
  @impl true
  def load(_paths, _status) do
    with :ok <- ok?(["daemon-reload"]) do
      ok?(["enable", "--now", @unit])
    end
  end

  @impl true
  def unload, do: ok?(["disable", "--now", @unit])

  @impl true
  def stop, do: ok?(["stop", @unit])

  @impl true
  def start, do: ok?(["start", @unit])

  @doc """
  Is the unit enabled, and is the owl running under it? From `systemctl
  --user show`, which answers for any unit name — `UnitFileState` is empty for
  one that is not installed. Enabled is what launchd calls loaded: the unit
  starts at login. `ExecMainStatus` is how the owl last exited; with no main
  pid and a non-zero status, the unit is crash-looping.
  """
  @impl true
  def status do
    case systemctl([
           "show",
           @unit,
           "--property=UnitFileState,MainPID,ExecMainStatus"
         ]) do
      {out, 0} -> parse_status(out)
      _ -> %{loaded: false, pid: nil, last_exit_code: nil}
    end
  end

  @doc false
  def parse_status(out) do
    fields =
      for line <- String.split(out, "\n"),
          [key, value] <- [String.split(line, "=", parts: 2)],
          into: %{},
          do: {key, String.trim(value)}

    %{
      loaded: fields["UnitFileState"] == "enabled",
      pid:
        case Integer.parse(fields["MainPID"] || "") do
          {pid, ""} when pid > 0 -> pid
          _ -> nil
        end,
      last_exit_code:
        case Integer.parse(fields["ExecMainStatus"] || "") do
          {code, ""} -> code
          _ -> nil
        end
    }
  end

  @doc "Whether logind keeps this user's services after their last session ends."
  @impl true
  def linger do
    case call([
           "loginctl",
           "show-user",
           Integer.to_string(ServiceManager.uid()),
           "--property=Linger",
           "--value"
         ]) do
      {out, 0} -> String.trim(out) == "yes"
      _ -> false
    end
  end

  defp systemctl(args), do: call(["systemctl", "--user" | args])
  defp call(argv), do: ServiceManager.call(runner(), argv)
  defp ok?(args), do: ServiceManager.ok?(systemctl(args))
end
