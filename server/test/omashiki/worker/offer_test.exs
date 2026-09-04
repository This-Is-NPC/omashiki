defmodule Omashiki.Worker.OfferTest do
  use Omashiki.DataCase, async: true

  import Omashiki.JobFixtures

  alias Omashiki.Worker.Offer

  test "from_claimed includes job payload" do
    user = user_fixture()
    {token, _} = api_token_fixture(user)

    payload = %{"instruction" => "ship it", "context" => %{"repo" => "demo"}}

    {job, attempt} =
      job_fixture(user, token, %{
        status: "provisioning",
        payload: payload,
        admitted_environment: %{"name" => "files", "sink" => "files"}
      })

    offer = Offer.from_claimed(job, attempt)
    assert offer.payload == payload

    map = Offer.to_map(offer)
    assert map["payload"] == payload

    assert {:ok, round} = Offer.from_map(map)
    assert round.payload == payload
  end
end
