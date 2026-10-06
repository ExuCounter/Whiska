defmodule Whiska.Rule.Held do
  @moduledoc """
  A mouse the person put on hold stops where it is
  (ADR-next-the-person-decides-what-reaches-them).

  `hold <branch>` stamps the record; this rule is what makes the stamp a stop.
  Every call the hook is asked about is refused, so the stop lands on the next
  one rather than at the end of a turn that may run for minutes — and the
  reason tells the mouse to end the turn here and say where it stopped. That
  message reaches the doorstep like any other and sits in the inbox, held,
  until `resume <branch>` lifts the stamp.

  What the hook is asked about is `Whiska.Install.matcher/0`: writes and shell
  commands. A read passes until the next of those, or until the turn ends on
  its own; widening the matcher to every tool would charge every read of every
  mouse the hook's startup, which is a trade for the person to make.

  Runs before `Whiska.Rule.Sniff`: a held mouse is refused for the hold, not
  for its mode, since the hold is the thing the person just did.
  """

  @type decision :: :allow | {:deny, String.t()}

  @doc "Decide one tool call for a mouse on branch `branch`, held or not."
  @spec decide(boolean(), String.t() | nil) :: decision()
  def decide(false, _branch), do: :allow

  def decide(true, branch) do
    {:deny,
     """
     Whiska denied this: this branch is on hold.

     The person put it on hold, so stop here: end the turn now with the
     needs-decision marker and a one-line pointer saying where you stopped and
     what is left. Retry nothing: every write and shell command is refused
     until the hold is lifted, which the person does with
     `resume #{branch || "<branch>"}`.
     """
     |> String.trim()}
  end
end
