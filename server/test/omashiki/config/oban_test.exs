defmodule Omashiki.Config.ObanTest do
  use ExUnit.Case, async: false

  @server Path.expand("../../..", __DIR__)

  test "zero omits the scheduler queue" do
    assert {output, 0} = config_output("0")
    assert output =~ "QUEUE=[webhooks: 5]"
  end

  test "positive limits keep the scheduler queue" do
    assert {output, 0} = config_output("3")
    assert output =~ "QUEUE=[scheduler: 3, webhooks: 5]"
  end

  test "negative and non-integer limits fail clearly" do
    for value <- ["-1", "nope"] do
      {output, status} = config_output(value)
      assert status != 0
      assert output =~ "OBAN_SCHEDULER_LIMIT must be a non-negative integer"
    end
  end

  defp config_output(value) do
    System.cmd(
      "mix",
      [
        "run",
        "--no-start",
        "-e",
        "IO.puts(\"QUEUE=\" <> inspect(Application.fetch_env!(:omashiki, Oban)[:queues]))"
      ],
      cd: @server,
      env: [{"OBAN_SCHEDULER_LIMIT", value}],
      stderr_to_stdout: true
    )
  end
end
