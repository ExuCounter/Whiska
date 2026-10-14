defmodule Whiska.Send do
  @moduledoc """
  `whiska send`: the person's words to a mouse already at work on its branch —
  a follow-up, notes on what it found, comments on its research document.

  The words travel as a file in the mouse's own worktree (`Whiska.Letters`), and
  what is typed into its pane is one fixed line pointing at it. Nothing the
  person or another mouse wrote is typed, so nothing in it can be read as a
  keystroke, cut short by the pane, or lost to a prompt box already holding
  text. A mouse mid-turn reads the line once its turn ends.

  An answer to a question is not sent here: `whiska reply` saves it against
  the question and the mouse's own hook takes it (ADR-0080).

  Once the pane takes the line, the questions the mouse was waiting on are
  superseded and the slot is free; the mouse's next message inherits it when
  one of them held it (ADR-0008). The line then asks the mouse to say so and
  ask again if the letter does not answer its question.
  """

  alias Whiska.Letters
  alias Whiska.Schema.Mouse
  alias Whiska.Storage

  @doc """
  Send the words in `file` to the live mouse on `branch`, from `main_checkout`,
  whose house is open. Answers the line for the person, or why nothing went.
  """
  @spec run(Path.t(), String.t(), Path.t(), %{herdr: module(), socket: Path.t()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(main_checkout, branch, file, via) do
    with {:ok, mouse} <- live_mouse(branch),
         {:ok, _text} <- Letters.read(file),
         {:ok, copy} <- copy(main_checkout, mouse, file) do
      busy? = busy?(via, mouse.pane)
      waiting = Storage.waiting_ids(mouse.mouse_id)

      case via.herdr.prompt(via.socket, mouse.pane, line(copy, waiting != [])) do
        :ok ->
          {:ok, ids} = Storage.supersede_for_letter(mouse.mouse_id, waiting)
          {:ok, sent(branch, busy?) <> retired(ids)}

        {:error, reason} ->
          {:error,
           "#{branch}'s pane #{mouse.pane} did not take the line (#{inspect(reason)}). " <>
             "The words are in #{copy}; send again once it is free."}
      end
    end
  end

  @doc """
  The one line typed into the mouse's pane; `asked?` when the mouse was waiting
  on a question of its own, which the letter retires.
  """
  @spec line(Path.t(), boolean()) :: String.t()
  def line(copy, false),
    do: "The person sent you a message. Read it in full, then act on it: #{copy}"

  def line(copy, true) do
    line(copy, false) <>
      " If it does not answer the question you were waiting on, say so and ask it again."
  end

  defp live_mouse(branch) do
    case Enum.find(Storage.alive_mice(), &(&1.branch == branch)) do
      %Mouse{pane: pane} = mouse when is_binary(pane) ->
        {:ok, mouse}

      _none ->
        {:error,
         "no live mouse of this repo is on #{branch}. `whiska mice` lists the ones there " <>
           "are; a new piece of work is `whiska spawn`."}
    end
  end

  defp copy(main_checkout, mouse, file) do
    case Letters.put(main_checkout, mouse.path, file) do
      {:ok, copy} ->
        {:ok, copy}

      {:error, reason} ->
        {:error, "could not copy #{file} into #{mouse.path} (#{inspect(reason)})."}
    end
  end

  defp busy?(via, pane) do
    match?({:ok, %{agent_status: "working"}}, via.herdr.pane(via.socket, pane))
  end

  defp sent(branch, true),
    do: "Sent to #{branch}. It is working, so it reads it after its current turn."

  defp sent(branch, false), do: "Sent to #{branch}; it reads it now."

  defp retired([]), do: ""

  defp retired([id]), do: " ##{id} no longer waits on you."
  defp retired(ids), do: " " <> Enum.map_join(ids, ", ", &"##{&1}") <> " no longer wait on you."
end
