defmodule Omashiki.Await do
  @moduledoc false

  import ExUnit.Assertions, only: [flunk: 1]

  def until(fun, remaining_ms \\ 2_000)

  def until(fun, remaining) when remaining <= 0 do
    if fun.(), do: true, else: flunk("condition not met")
  end

  def until(fun, remaining) do
    if fun.() do
      true
    else
      Process.sleep(10)
      until(fun, remaining - 10)
    end
  end
end
