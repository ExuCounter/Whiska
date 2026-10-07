defmodule Whiska.Test.QuietSidebar do
  @moduledoc """
  herdr's sidebar calls, answered the way a herdr with no workspaces answers
  them. A house asks on every board build, so a test about something else uses
  this as a setup rather than stubbing each call; a test's own stubs still win.
  """
  import Mox

  @spec stub_sidebar(map()) :: :ok
  def stub_sidebar(_context \\ %{}) do
    stub(Whiska.Herdr.Mock, :workspaces, fn _socket -> {:ok, []} end)
    stub(Whiska.Herdr.Mock, :report_metadata, fn _socket, _ws, _tokens, _ttl -> :ok end)
    stub(Whiska.Herdr.Mock, :move_block, fn _socket, _ids, _before -> {:ok, []} end)
    stub(Whiska.Herdr.Mock, :version, fn _socket -> {:ok, "0.9.3"} end)
    :ok
  end
end
