defmodule Caracola.TutorialTest do
  # The tutorial services use fixed ports and global names
  use ExUnit.Case, async: false

  alias Caracola.Tutorial.Office

  # The steps of guides/03-tutorial.md, run by Caracola.Tutorial.launch/0
  test "tutorial" do
    on_exit(fn -> Caracola.Tutorial.stop() end)
    assert Caracola.Tutorial.launch() == :ok
  end

  # The steps of guides/15-small-pbx.md, run by Caracola.Tutorial.Office.launch/0
  test "small PBX tutorial" do
    on_exit(fn -> Office.stop() end)
    assert Office.launch() == :ok
  end
end
