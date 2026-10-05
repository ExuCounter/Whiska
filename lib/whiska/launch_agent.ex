defmodule Whiska.LaunchAgent do
  @moduledoc """
  The owl under `launchd`, on macOS (ADR-0001, ADR-0040): one user
  LaunchAgent, `com.whiska.owl`, that starts the owl at login and restarts it
  if it crashes. `Whiska.SystemdUnit` is the same job on Linux; both answer
  `Whiska.ServiceManager`.

  Three files, all under the person's own home:

  - `~/Library/LaunchAgents/com.whiska.owl.plist` — the job. It runs the
    wrapper, not the escript: launchd's `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`,
    so `#!/usr/bin/env escript` would never resolve, and baking the runtime's
    absolute path in at install time would break silently on the next Erlang
    upgrade. The wrapper resolves both at every launch.
  - `~/.whiska/owl.sh` — the wrapper, `Whiska.ServiceManager.wrapper/0`,
    generated from the same shell fragments the hook shim and the statusline
    script are built from (`Whiska.Install`), so the three cannot drift.
  - `~/.whiska/owl.log` — stdout and stderr, appended. No rotation yet.

  `KeepAlive` is `SuccessfulExit = false`: launchd restarts a crash and leaves
  a clean exit alone. That is what lets `whiska owl stop` mean "lights off for
  now" — it sends `TERM`, the BEAM exits 0, the job stays loaded and comes back
  at the next login or `whiska owl start` — without booting the job out.
  Uninstall is the separate verb that removes the files.

  Everything is a pure value or a write under a given home, and every
  launchctl call goes through a runner that tests replace. The real one is
  `launchctl/1`.
  """

  @behaviour Whiska.ServiceManager

  alias Whiska.ServiceManager

  @label "com.whiska.owl"

  @type runner :: ([String.t()] -> {String.t(), non_neg_integer()})

  @impl true
  def name, do: "launchd"

  @impl true
  def noun, do: "launch agent"

  @doc "The job's label."
  @impl true
  def label, do: @label

  @doc "The service target launchctl addresses: the user's gui domain plus the label."
  @spec service(pos_integer()) :: String.t()
  def service(uid), do: "gui/#{uid}/#{@label}"

  @doc """
  Where the three files go, given the user's home (for `Library/LaunchAgents`)
  and the whiska home (`~/.whiska`, where the open-houses record lives too).
  """
  @spec paths(Path.t(), Path.t()) :: ServiceManager.paths()
  def paths(user_home, whiska_home) do
    %{
      job: Path.join(user_home, "Library/LaunchAgents/#{@label}.plist"),
      wrapper: Path.join(whiska_home, "owl.sh"),
      log: Path.join(whiska_home, "owl.log")
    }
  end

  @doc "The paths on this machine, honouring the test config's overrides."
  @impl true
  def paths, do: paths(ServiceManager.user_home(), Whiska.OpenHouses.home())

  @doc "The launchctl runner: the `:launchctl` setting, else the real binary."
  @spec runner() :: runner()
  def runner, do: Application.get_env(:whiska, :launchctl) || (&launchctl/1)

  @doc "Run the real launchctl with these arguments."
  @spec launchctl([String.t()]) :: {String.t(), non_neg_integer()}
  def launchctl(args), do: ServiceManager.cmd("launchctl", args)

  @doc "launchd is part of macOS; there is nothing to check."
  @impl true
  def ready, do: :ok

  @doc """
  The plist. `env` is the installing shell's environment; the variables the
  owl needs are copied through, nothing else.
  """
  @spec plist(ServiceManager.paths(), %{optional(String.t()) => String.t()}) :: String.t()
  def plist(%{wrapper: wrapper, log: log}, env) do
    environment =
      case ServiceManager.passthrough(env) do
        [] ->
          ""

        pairs ->
          "  <key>EnvironmentVariables</key>\n  <dict>\n" <>
            Enum.map_join(pairs, "", fn {k, v} ->
              "    <key>#{escape(k)}</key>\n    <string>#{escape(v)}</string>\n"
            end) <>
            "  </dict>\n"
      end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{@label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>/bin/bash</string>
        <string>#{escape(wrapper)}</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <dict>
        <key>SuccessfulExit</key>
        <false/>
      </dict>
      <key>StandardOutPath</key>
      <string>#{escape(log)}</string>
      <key>StandardErrorPath</key>
      <string>#{escape(log)}</string>
    #{environment}</dict>
    </plist>
    """
  end

  defp escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc "Write the wrapper and the plist. Safe to re-run."
  @impl true
  def install(paths, env), do: ServiceManager.write(paths, plist(paths, env))

  @doc "Remove the wrapper and the plist. The log stays."
  @impl true
  def uninstall(paths), do: ServiceManager.remove(paths)

  @doc "Is the plist there? Installed says nothing about loaded — `status/2` does."
  @impl true
  def installed?(%{job: plist}), do: File.exists?(plist)

  @doc "Load the job into the user's gui domain; RunAtLoad starts the owl at once."
  @spec bootstrap(ServiceManager.paths(), pos_integer(), runner()) :: :ok | {:error, String.t()}
  def bootstrap(%{job: plist}, uid, run), do: ok?(run, ["bootstrap", "gui/#{uid}", plist])

  @doc "Unload the job. A running owl is stopped with it."
  @spec bootout(pos_integer(), runner()) :: :ok | {:error, String.t()}
  def bootout(uid, run), do: ok?(run, ["bootout", service(uid)])

  @doc "Ask the owl to exit: TERM, which the BEAM turns into a clean exit 0."
  @spec stop(pos_integer(), runner()) :: :ok | {:error, String.t()}
  def stop(uid, run), do: ok?(run, ["kill", "TERM", service(uid)])

  @doc "Start the owl now, without waiting for the next login."
  @spec start(pos_integer(), runner()) :: :ok | {:error, String.t()}
  def start(uid, run), do: ok?(run, ["kickstart", service(uid)])

  @doc "A loaded job is booted out first: launchd will not bootstrap a label twice."
  @impl true
  def load(paths, status) do
    uid = ServiceManager.uid()
    run = runner()

    with :ok <- if(status.loaded, do: bootout(uid, run), else: :ok) do
      bootstrap(paths, uid, run)
    end
  end

  @impl true
  def unload, do: bootout(ServiceManager.uid(), runner())

  @impl true
  def stop, do: stop(ServiceManager.uid(), runner())

  @impl true
  def start, do: start(ServiceManager.uid(), runner())

  @impl true
  def linger, do: :not_applicable

  @doc """
  Is the job loaded, and is the owl running under it? From `launchctl print`,
  which fails when the job is not loaded and otherwise prints a `pid = N`
  line only while the process is alive. A launchctl that is not there at all
  is "not loaded" too.

  `last_exit_code` is how the owl last ended, when launchd has seen it end at
  all — it prints `(never exited)` until then. With no pid and a non-zero code
  the job is loaded and crash-looping, which is the one thing "loaded, owl not
  running" cannot tell apart on its own (ADR-0040, 2026-09-28 note).
  """
  @spec status(pos_integer(), runner()) :: ServiceManager.status()
  def status(uid, run) do
    case ServiceManager.call(run, ["print", service(uid)]) do
      {out, 0} ->
        %{
          loaded: true,
          pid: integer_field(out, ~r/^\s*pid = (\d+)\s*$/m),
          last_exit_code: integer_field(out, ~r/^\s*last exit code = (-?\d+)\s*$/m)
        }

      _ ->
        %{loaded: false, pid: nil, last_exit_code: nil}
    end
  end

  defp integer_field(out, regex) do
    case Regex.run(regex, out) do
      [_, n] -> String.to_integer(n)
      nil -> nil
    end
  end

  @doc "`status/2` with this machine's uid and runner."
  @impl true
  def status, do: status(ServiceManager.uid(), runner())

  defp ok?(run, args), do: ServiceManager.ok?(ServiceManager.call(run, args))
end
