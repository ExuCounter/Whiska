#!/usr/bin/env bash
# Times the hook shim and the tab bar script with an owl answering and without
# one, against a throwaway repo, so nothing lands in a real house.
#
#   bench.sh <whiska-binary> [runs]
#
# Starts an owl of its own on a throwaway whiska home, under /tmp because a
# socket's path is capped at 104 bytes on macOS, and stops it after. The tab
# bar line reads this machine's own open-houses record, read-only, as
# `whiska statusline` does, so both lines do the same work.

set -euo pipefail

whiska="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
runs="${2:-200}"
shim_bash="${SHIM_BASH:-/bin/bash}"

work="$(mktemp -d)"
home="$(mktemp -d /tmp/wsk.XXXXXX)"
main="$work/myrepo"
worktree="$main/worktrees/feat-x"
mkdir -p "$main/.git/worktrees/feat-x" "$worktree/lib"
printf 'gitdir: %s/.git/worktrees/feat-x\n' "$main" > "$worktree/.git"

# The shim and the tab bar script exactly as `whiska init` and `whiska owl
# install` write them, from this checkout's code.
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
(cd "$repo" && mix run --no-start -e 'IO.write(Whiska.Install.shim())') > "$work/whiska.sh"
(cd "$repo" && mix run --no-start -e 'IO.write(Whiska.Install.herdr_status_script())') \
  > "$work/herdr-status.sh"

edit="{\"cwd\":\"$worktree\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$worktree/lib/a.ex\",\"old_string\":\"a\",\"new_string\":\"b\"}}"
stop="{\"cwd\":\"$worktree\",\"last_assistant_message\":\"bench\"}"
printf '%s' "$edit" > "$work/edit.json"
printf '%s' "$stop" > "$work/stop.json"

# The owl's own code, with no house open: it answers both sockets and collects
# nothing. `whiska owl` itself refuses to start beside a supervised owl, and
# two owls must never collect the same doorsteps.
(cd "$repo" && MIX_ENV=prod exec mix run --no-halt -e "
  {:ok, owl} = Whiska.Owl.start_link(herdr_socket: \"/nonexistent\", sockets: \"$home\")
  Process.unlink(owl)
" > "$work/owl.log" 2>&1) &
owl=$!
trap 'kill $owl 2>/dev/null; rm -rf "$work" "$home"' EXIT
for _ in $(seq 300); do
  [ -S "$home/hook.sock" ] && [ -S "$home/owl.sock" ] && break
  perl -e 'select(undef, undef, undef, 0.1)'
done

# A number taken while the owl is silent would be the escript's, mislabelled.
case "$(printf 'hook 1 pre-tool-use 2\n\n{}' | nc -w 2 -U "$home/hook.sock")" in
  "ok "*) ;;
  *)
    echo "the owl did not answer:" >&2
    cat "$work/owl.log" >&2
    exit 1
    ;;
esac

export WHISKA_BIN="$whiska" CLAUDE_PROJECT_DIR="$worktree" WHISKA_HOME="$home"

per_run() {
  local n="$1"
  shift
  perl -MTime::HiRes=time -e '
    my ($n, $cmd) = @ARGV;
    my $t = time;
    for (1 .. $n) { system($cmd) }
    printf "%8.2f ms\n", (time - $t) / $n * 1000;
  ' "$n" "$*"
}

slow=$((runs / 10 > 5 ? runs / 10 : 5))

printf '%-52s' "bash -c true"
per_run "$runs" "$shim_bash -c true"
printf '%-52s' "pre-tool-use, the owl answering"
per_run "$runs" "$shim_bash $work/whiska.sh pre-tool-use < $work/edit.json > /dev/null"
printf '%-52s' "pre-tool-use, no owl: the escript"
per_run "$slow" "WHISKA_HOOK_SOCKET=/nonexistent $shim_bash $work/whiska.sh pre-tool-use < $work/edit.json > /dev/null"
printf '%-52s' "stop, the owl answering"
per_run "$runs" "$shim_bash $work/whiska.sh stop < $work/stop.json > /dev/null"
printf '%-52s' "stop, no owl: the escript"
per_run "$slow" "WHISKA_HOOK_SOCKET=/nonexistent $shim_bash $work/whiska.sh stop < $work/stop.json > /dev/null"
printf '%-52s' "tab bar line, the owl answering"
per_run "$runs" "/bin/bash $work/herdr-status.sh > /dev/null"
printf '%-52s' "tab bar line the escript way (whiska statusline)"
per_run "$slow" "$whiska statusline > /dev/null 2>&1"
