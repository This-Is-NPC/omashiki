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
    assert offer.attempt_number == attempt.number
    assert offer.user_id == job.user_id
    assert offer.repository == job.repository
    assert offer.environment == job.environment
    assert offer.admitted_environment_digest == job.admitted_environment_digest
    assert offer.admitted_repository_digest == job.admitted_repository_digest
    assert offer.admitted_plugin_digest == job.admitted_plugin_digest

    map = Offer.to_map(offer)
    assert map["payload"] == payload
    assert map["attempt_number"] == attempt.number
    assert map["user_id"] == job.user_id
    assert map["environment"] == job.environment
    assert map["admitted_environment_digest"] == job.admitted_environment_digest
    assert map["admitted_plugin_digest"] == job.admitted_plugin_digest

    assert {:ok, round} = Offer.from_map(map)
    assert round.payload == payload
    assert round.attempt_number == attempt.number
    assert round.user_id == job.user_id
    assert round.environment == job.environment
    assert round.admitted_environment_digest == job.admitted_environment_digest
    assert round.admitted_plugin_digest == job.admitted_plugin_digest
  end
end
