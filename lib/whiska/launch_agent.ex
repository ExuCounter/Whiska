defmodule Whiska.LaunchAgent do
  @moduledoc """
  The owl under `launchd` (ADR-0001, ADR-0040): one user LaunchAgent,
  `com.whiska.owl`, that starts the owl at login and restarts it if it
  crashes.

  Three files, all under the person's own home:

  - `~/Library/LaunchAgents/com.whiska.owl.plist` — the job. It runs the
    wrapper, not the escript: launchd's `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`,
    so `#!/usr/bin/env escript` would never resolve, and baking the runtime's
    absolute path in at install time would break silently on the next Erlang
    upgrade. The wrapper resolves both at every launch.
  - `~/.whiska/owl.sh` — the wrapper, generated from the same shell fragments
    the hook shim and the statusline script are built from
    (`Whiska.Install`), so the three cannot drift.
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

  alias Whiska.Install

  @label "com.whiska.owl"

  # Copied from the installing shell into the job's environment, when set.
  # launchd gives a job almost no environment of its own, and the owl needs
  # herdr's socket to hear about idle mice (a fallback exists in code).
  @passthrough ~w(HERDR_SOCKET_PATH WHISKA_BIN WHISKA_ESCRIPT WHISKA_HOME)

  @type paths :: %{plist: Path.t(), wrapper: Path.t(), log: Path.t()}
  @type status :: %{loaded: boolean(), pid: pos_integer() | nil}
  @type runner :: ([String.t()] -> {String.t(), non_neg_integer()})

  @doc "The job's label."
  @spec label() :: String.t()
  def label, do: @label

  @doc "The service target launchctl addresses: the user's gui domain plus the label."
  @spec service(pos_integer()) :: String.t()
  def service(uid), do: "gui/#{uid}/#{@label}"

  @doc """
  Where the three files go, given the user's home (for `Library/LaunchAgents`)
  and the whiska home (`~/.whiska`, where the open-houses record lives too).
  """
  @spec paths(Path.t(), Path.t()) :: paths()
  def paths(user_home, whiska_home) do
    %{
      plist: Path.join(user_home, "Library/LaunchAgents/#{@label}.plist"),
      wrapper: Path.join(whiska_home, "owl.sh"),
      log: Path.join(whiska_home, "owl.log")
    }
  end

  @doc "The paths on this machine, honouring the test config's overrides."
  @spec paths() :: paths()
  def paths, do: paths(user_home(), Whiska.OpenHouses.home())

  @doc "The user's home: the `:user_home` setting, else the real one."
  @spec user_home() :: Path.t()
  def user_home, do: Application.get_env(:whiska, :user_home) || System.user_home!()

  @doc "The uid launchd's gui domain is keyed by: the `:uid` setting, else `id -u`."
  @spec uid() :: pos_integer()
  def uid do
    Application.get_env(:whiska, :uid) ||
      case System.cmd("id", ["-u"]) do
        {out, 0} -> out |> String.trim() |> String.to_integer()
      end
  end

  @doc "The launchctl runner: the `:launchctl` setting, else the real binary."
  @spec runner() :: runner()
  def runner, do: Application.get_env(:whiska, :launchctl) || (&launchctl/1)

  @doc "Run the real launchctl with these arguments."
  @spec launchctl([String.t()]) :: {String.t(), non_neg_integer()}
  def launchctl(args), do: System.cmd("launchctl", args, stderr_to_stdout: true)

  @doc """
  The plist. `env` is the installing shell's environment; the variables the
  owl needs are copied through, nothing else.
  """
  @spec plist(paths(), %{optional(String.t()) => String.t()}) :: String.t()
  def plist(%{wrapper: wrapper, log: log}, env) do
    passthrough =
      for name <- @passthrough, value = env[name], is_binary(value), value != "" do
        {name, value}
      end

    environment =
      case passthrough do
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

  @wrapper """
           #!/usr/bin/env bash
           # Whiska's owl, as launchd runs it (ADR-0040). Written by `whiska owl
           # install`; do not edit, it is overwritten on the next install.
           #
           # launchd starts a job with almost no PATH, so the binary and the
           # Erlang runtime are resolved here, at every launch, exactly as the
           # hook shim resolves them - the same fragments, generated from the
           # same source. An Erlang upgrade needs no reinstall.

           """ <>
             Install.resolve_whiska() <>
             """
             if [ -z "$whiska_bin" ]; then
               echo "whiska: no whiska binary found (set WHISKA_BIN in the plist, or install to ~/.local/bin)" >&2
               exit 1
             fi

             """ <>
             Install.resolve_escript() <>
             """
             # No arguments: the owl reopens every house in its record (ADR-0039).
             if [ -n "$escript_bin" ]; then
               exec "$escript_bin" "$whiska_bin" owl
             fi
             exec "$whiska_bin" owl
             """

  @doc "The wrapper script launchd runs."
  @spec wrapper() :: String.t()
  def wrapper, do: @wrapper

  @doc "Write the wrapper and the plist. Safe to re-run."
  @spec install(paths(), map()) :: :ok | {:error, term()}
  def install(%{plist: plist, wrapper: wrapper} = paths, env) do
    with :ok <- File.mkdir_p(Path.dirname(wrapper)),
         :ok <- File.write(wrapper, @wrapper),
         :ok <- File.chmod(wrapper, 0o755),
         :ok <- File.mkdir_p(Path.dirname(plist)) do
      File.write(plist, plist(paths, env))
    end
  end

  @doc "Remove the wrapper and the plist. The log stays."
  @spec uninstall(paths()) :: :ok | {:error, :not_installed}
  def uninstall(%{plist: plist, wrapper: wrapper} = paths) do
    if installed?(paths) do
      File.rm(plist)
      File.rm(wrapper)
      :ok
    else
      {:error, :not_installed}
    end
  end

  @doc "Is the plist there? Installed says nothing about loaded — `status/2` does."
  @spec installed?(paths()) :: boolean()
  def installed?(%{plist: plist}), do: File.exists?(plist)

  @doc "Load the job into the user's gui domain; RunAtLoad starts the owl at once."
  @spec bootstrap(paths(), pos_integer(), runner()) :: :ok | {:error, String.t()}
  def bootstrap(%{plist: plist}, uid, run), do: ok?(run.(["bootstrap", "gui/#{uid}", plist]))

  @doc "Unload the job. A running owl is stopped with it."
  @spec bootout(pos_integer(), runner()) :: :ok | {:error, String.t()}
  def bootout(uid, run), do: ok?(run.(["bootout", service(uid)]))

  @doc "Ask the owl to exit: TERM, which the BEAM turns into a clean exit 0."
  @spec stop(pos_integer(), runner()) :: :ok | {:error, String.t()}
  def stop(uid, run), do: ok?(run.(["kill", "TERM", service(uid)]))

  @doc "Start the owl now, without waiting for the next login."
  @spec start(pos_integer(), runner()) :: :ok | {:error, String.t()}
  def start(uid, run), do: ok?(run.(["kickstart", service(uid)]))

  @doc """
  Is the job loaded, and is the owl running under it? From `launchctl print`,
  which fails when the job is not loaded and otherwise prints a `pid = N`
  line only while the process is alive.
  """
  @spec status(pos_integer(), runner()) :: status()
  def status(uid, run) do
    case run.(["print", service(uid)]) do
      {out, 0} ->
        pid =
          case Regex.run(~r/^\s*pid = (\d+)\s*$/m, out) do
            [_, n] -> String.to_integer(n)
            nil -> nil
          end

        %{loaded: true, pid: pid}

      _ ->
        %{loaded: false, pid: nil}
    end
  end

  @doc "`status/2` with this machine's uid and runner."
  @spec status() :: status()
  def status, do: status(uid(), runner())

  defp ok?({_, 0}), do: :ok
  defp ok?({out, _}), do: {:error, String.trim(out)}
end
