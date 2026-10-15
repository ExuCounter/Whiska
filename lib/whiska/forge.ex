defmodule Whiska.Forge do
  @moduledoc """
  What Whiska reads of a merge request on the forge that hosts it, with one
  module per forge behind this behaviour, so nothing outside a module knows
  which forge it talks to (ADR-0060). `Whiska.Forge.GitLab` reads through
  `glab`; `Whiska.Forge.GitHub` only opens one so far, and its links are
  parsed and labelled but not read.

  No callback writes. Every read goes through `Whiska.Forge.CLI`, which runs
  only GETs. Opening a merge request is the separate `Whiska.Forge.Opener`
  behaviour, which `whiska pr` alone calls, and replying on a thread the
  separate `Whiska.Forge.Replier`, which `whiska push` alone calls, each on
  the person's word (ADR-0085).

  An answer is `{:ok, value}`, `:missing` for a 404, or unknown with the
  forge's retry time when it sent one. Unknown is never an answer about the
  merge request: a forge that cannot be read says nothing.
  """

  alias Whiska.Forge.GitHub
  alias Whiska.Forge.GitLab

  @type ref :: %{
          forge: module(),
          host: String.t(),
          project: String.t(),
          number: pos_integer(),
          url: String.t()
        }

  @typedoc "A project on a forge, before any merge request of it is known."
  @type project :: %{forge: module(), host: String.t(), project: String.t()}

  @type run :: %{tool: Path.t() | nil, cwd: Path.t(), timeout_ms: pos_integer()}

  @type answer(t) :: {:ok, t} | :missing | {:unknown, term(), pos_integer() | nil}

  @type pipeline :: %{
          id: pos_integer(),
          status: :running | :passed | :failed | :other,
          sha: String.t() | nil
        }

  @type snapshot :: %{
          state: :open | :merged | :closed,
          head_sha: String.t() | nil,
          pipeline: pipeline() | nil,
          notes_count: non_neg_integer(),
          updated_at: String.t() | nil,
          source_branch: String.t() | nil,
          ready?: boolean(),
          blocker: blocker()
        }

  @typedoc """
  The one thing the forge names as keeping a merge request from merging, or
  nil when nothing does, or when it is the pipeline, which the pipeline says.
  """
  @type blocker ::
          :approval | :conflict | :draft | :threads | :rebase | :blocked | nil

  @type note :: %{
          id: pos_integer(),
          author_id: pos_integer(),
          author: String.t(),
          system?: boolean(),
          discussion_id: String.t() | nil,
          open?: boolean()
        }

  @callback parse(url :: String.t()) :: {:ok, ref()} | :error
  @callback label(ref()) :: String.t()
  @callback tool() :: String.t()
  @callback merge_request(ref(), run()) :: answer(snapshot())
  @callback notes(ref(), run()) :: answer(%{threads_open: non_neg_integer(), notes: [note()]})
  @callback member?(ref(), user_id :: pos_integer(), run()) :: answer(boolean())
  @callback me(ref(), run()) :: answer(%{id: pos_integer(), username: String.t()})
  @callback project_readable?(ref(), run()) :: answer(boolean())

  @doc """
  The link of a merge request open from `branch` on `project`, into any
  branch, one into `base` first, or nil when there is none.
  """
  @callback open_from(project(), branch :: String.t(), base :: String.t() | nil, run()) ::
              answer(String.t() | nil)

  @optional_callbacks merge_request: 2,
                      notes: 2,
                      member?: 3,
                      me: 2,
                      project_readable?: 2,
                      open_from: 4

  @forges [GitLab, GitHub]

  @spec for_url(String.t()) :: {:ok, ref()} | :error
  def for_url(url) when is_binary(url) do
    Enum.find_value(@forges, :error, fn forge ->
      case forge.parse(url) do
        {:ok, ref} -> {:ok, ref}
        :error -> nil
      end
    end)
  end

  def for_url(_url), do: :error

  @spec label(ref()) :: String.t()
  def label(%{forge: forge} = ref), do: forge.label(ref)

  @spec reads?(ref()) :: boolean()
  def reads?(%{forge: forge}) do
    Code.ensure_loaded?(forge) and function_exported?(forge, :merge_request, 2)
  end

  @doc "How `ref`'s forge is read from `cwd`: its tool, wherever it is installed."
  @spec run(ref(), Path.t(), pos_integer()) :: run()
  def run(%{forge: forge}, cwd, timeout_ms),
    do: %{tool: Whiska.Forge.CLI.find(forge.tool()), cwd: cwd, timeout_ms: timeout_ms}

  @doc """
  The forge that opens a merge request from `main_checkout`: GitLab when its
  `origin` remote says so, GitHub otherwise. Its tool has to be installed.
  """
  @spec opener(Path.t()) :: {:ok, module()} | {:error, String.t()}
  def opener(main_checkout) do
    forge = if String.contains?(origin(main_checkout) || "", "gitlab"), do: GitLab, else: GitHub

    if Whiska.Forge.CLI.find(forge.tool()),
      do: {:ok, forge},
      else:
        {:error,
         "#{forge.tool()} is not installed, so no merge request was opened and nothing pushed."}
  end

  @doc "The host `main_checkout`'s `origin` remote is on, for a read before any link exists."
  @spec origin_host(Path.t()) :: String.t() | nil
  def origin_host(main_checkout) do
    with url when is_binary(url) <- origin(main_checkout),
         [_, host] <-
           Regex.run(~r{\A(?:[a-z+]+://)?(?:[^@/]+@)?([A-Za-z0-9.-]+)(?::[0-9]+)?[:/]}, url) do
      host
    else
      _ -> nil
    end
  end

  @doc """
  The project `main_checkout`'s `origin` remote names, on a forge that can
  look a merge request up by its branch: GitLab, when `origin`'s host says so.
  A merge request is looked for nowhere else (ADR-0060).
  """
  @spec origin_project(Path.t()) :: {:ok, project()} | :error
  def origin_project(main_checkout) do
    with url when is_binary(url) <- origin(main_checkout),
         url = url |> String.trim_trailing("/") |> String.replace_suffix(".git", ""),
         [scheme, host, port, project] <-
           Regex.run(
             ~r{\A([a-z+]+://)?(?:[^@/]+@)?([A-Za-z0-9.-]+)(:[0-9]+)?[:/]/?([A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)+)\z},
             url,
             capture: :all_but_first
           ),
         true <- String.contains?(host, "gitlab") do
      # Only an https remote's port is the web's; an ssh one's is not.
      host = if scheme == "https://", do: host <> port, else: host
      {:ok, %{forge: GitLab, host: host, project: project}}
    else
      _ -> :error
    end
  end

  defp origin(main_checkout) do
    case System.cmd("git", ["remote", "get-url", "origin"],
           cd: main_checkout,
           stderr_to_stdout: true
         ) do
      {url, 0} -> String.trim(url)
      _ -> nil
    end
  end
end

defmodule Whiska.Forge.Opener do
  @moduledoc """
  Opening a merge request: the one thing Whiska asks of a forge that writes,
  run by `whiska pr` in the person's own command and never by the owl
  (ADR-0085); and showing one in the browser, on the person's key. A module
  that opens one is also a `Whiska.Forge`, whose `tool/0` it runs.
  """

  @callback create_args(
              main_checkout :: Path.t(),
              branch :: String.t(),
              base :: String.t(),
              title :: String.t(),
              body_file :: Path.t()
            ) :: {:ok, [String.t()]} | {:error, String.t()}
  @callback link(output :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  @callback browse_args(Whiska.Forge.ref()) :: [String.t()]
end

defmodule Whiska.Forge.Replier do
  @moduledoc """
  Replying on a merge request's thread and resolving it: the writes `whiska
  push` makes, in the person's own command and never the owl's (ADR-0060).
  The thread id is one `whiska push` checked; the body is a JSON file, so the
  reply's text is never on a command line.
  """

  @callback reply_args(Whiska.Forge.ref(), thread_id :: String.t(), json_file :: Path.t()) ::
              [String.t()]
  @callback resolve_args(Whiska.Forge.ref(), thread_id :: String.t()) :: [String.t()]
  @callback thread_id?(String.t()) :: boolean()
  @callback thread(Whiska.Forge.ref(), thread_id :: String.t(), Whiska.Forge.run()) ::
              Whiska.Forge.answer(%{author: String.t(), body: String.t(), note_id: pos_integer()})
end
