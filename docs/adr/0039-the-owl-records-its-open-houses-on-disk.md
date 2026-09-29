# The owl records its open houses on disk, and that record is what makes a whiska

`whiska owl` opened only the houses named on its command line — by default the repo it
was started in — and remembered nothing between runs. Started from one repo, it kept one
house, and the person asked why the other project they were working in never showed up.
At the same time the statusline's whiska headcount (ADR-0027, second addendum) counted
*any* live Claude pane sitting in a repo root that had a house file on disk, so a repo
initialised once, months ago, with a session open in it, was counted as a whiska while no
owl was collecting there. The person saw `🐈 3 whiskas` and knew they had two.

Both complaints have the same root: nothing wrote down which houses the owl actually
has open. The owl knew, in memory, and died with it; everything else guessed from files
on disk that mean "a house exists", which is a different question (ADR-0003).

## Decision

The owl keeps an **open-houses record**: a plain text file, one main checkout per line,
at `~/.whiska/houses` — the machine-level folder ADR-0025 already reserves for the
global socket. The owl adds a line when it opens a house and removes it when it shuts
one. Stopping the whole owl leaves the file alone: that is exactly the memory the next
start restores from.

- **`whiska owl` with no arguments** opens every house in the record, plus the current
  checkout's house if that house already exists. With nothing recorded and no house
  here, it opens the house here, as before, so a first run still works. A recorded
  checkout that is no longer a git checkout is said so and dropped from the record.
- **`whiska owl <repo>...`** opens those *as well as* everything recorded, and they are
  in the record from then on. Arguments add; they never replace, so the record never
  lists a house the owl does not have open. Until `whiska stop` exists, taking a house
  out means shutting it or editing the file by hand — it is plain text for that reason.
- **A whiska is a house in the open-houses record with a live agent pane in its repo
  root.** That is the definition the statusline's `🐈` headcount and its `⚡ … waiting
  elsewhere` segment now count, replacing "any live pane in a repo root that has a house
  file". A house the owl is not collecting cannot have fresh questions, so it has no
  business in either segment. The repo the line is drawn in counts while its own house
  is open, whichever of its panes is live.
- **`whiska doctor` shows the record**: which houses are open per the file, and a warning
  when the repo being examined is not among them — the one case the headcount cannot
  explain by itself.

## A crashed owl must not lie forever

The record is written by the owl and outlives it, so on its own it would say "open" for
as long as nobody restarted. It is therefore **trusted only while an owl is in the
process table** — `Whiska.OpenHouses.open/2` returns nothing when `Whiska.Owl.pids/0`,
the probe the doctor and the statusline already share (ADR-0027, second addendum), finds
no owl. With the owl down, no house is open, and the statusline reads `🦉 owl down`,
which is the signal that matters then. (Since ADR-0048 the statusline reads the record
with `read/1` rather than through this guard: what it lists is what is *waiting*, and a
question already recorded is waiting whether or not an owl is awake — the same reading
`whiska waiting` does. The guard still holds for the doctor.) The doctor prints what the file says with "none is open while the owl is down"
beside it.

## Why this is not the house registry that was rejected before

The statusline-counts work (ADR-0027, first addendum) turned down a machine-level file
for counting *mice*, because the house's `died_at` is only set while the owl runs and the
statusline is precisely the thing that must keep working when the owl is down; herdr's
pane list is the honest source for liveness. This record is different in both respects:

- It is about **houses, not mice** — whether the owl has a project's lights on, a fact
  only the owl knows and one that changes only when the owl opens or shuts something.
  Nothing in it goes stale on its own; it goes stale only when the owl dies.
- That one way of going stale is **guarded by the owl liveness probe**. Liveness of the
  sessions themselves still comes from herdr, exactly as before; the record only says
  which repos to look in.

## Consequences

- ADR-0025's addendum defined a whiska as a live agent pane in a repo root that has a
  house; that definition is revised there to "in the open-houses record with a live
  pane". `Whiska.Statusline.whiskas/2` takes the record as an argument and stays pure.
- The `.whiska` home is `~/.whiska`, overridable by the `:home` application setting and
  the `WHISKA_HOME` variable. Tests point it into `_build` so they can never touch the
  person's own record; the owl tests that open houses always pass an explicit working
  directory for the same reason.
- When the global socket lands (ADR-0025), "which houses are open" becomes a question to
  the owl and the file is no longer read by anyone but the owl restoring from it. The
  file itself stays: the socket cannot survive the owl either.
- The house still persists on disk regardless (ADR-0003). The record is about lights on
  or off, never about existence; dropping a checkout from it destroys nothing.
