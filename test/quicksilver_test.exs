defmodule QuicksilverTest do
  use ExUnit.Case
  doctest Quicksilver

  test "greets the world" do
    assert Quicksilver.hello() == :world
  end
end
