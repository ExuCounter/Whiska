defmodule Whiska.BriefTest do
  use ExUnit.Case, async: true

  alias Whiska.Brief

  test "each brief renders whole: a mouse's carries its task and the finished marker" do
    for mode <- ["build", "sniff"] do
      text = Brief.render(mode, "Make the CSV page sortable by date.")
      assert text =~ "Make the CSV page sortable by date.", mode
      refute text =~ "{{", mode
      assert text =~ String.duplicate("⁣", 3), mode
    end

    refute Brief.render(:main) =~ "{{"
  end
end
