defmodule Omashiki.Jobs.Contract.Payload.V2Test do
  use ExUnit.Case, async: true

  alias Omashiki.Jobs.Contract.Payload.V2

  test "requires instruction and accepts JSON context" do
    payload = %{"instruction" => "make the change", "context" => %{"issue" => 42}}
    assert {:ok, ^payload} = V2.validate(payload)
  end

  test "rejects harness and provider control fields" do
    for key <- ~w(harness provider auth model) do
      assert {:error, errors} = V2.validate(%{"instruction" => "run", key => "value"})
      assert %{field: "payload.#{key}", code: "control_field_not_allowed"} in errors
    end
  end

  test "rejects unknown fields and non-object context" do
    assert {:error, errors} = V2.validate(%{"instruction" => "run", "parts" => []})
    assert %{field: "payload.parts", code: "unknown_field"} in errors

    assert {:error, errors} = V2.validate(%{"instruction" => "run", "context" => [1, 2]})
    assert %{field: "payload.context", code: "object_required"} in errors
  end
end
