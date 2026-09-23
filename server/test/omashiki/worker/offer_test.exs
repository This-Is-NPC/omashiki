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

    house = Ecto.UUID.generate()
    map = Offer.to_map(%{offer | house_id: house})
    assert map["house_id"] == house
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
    assert round.house_id == house

    assert {:error, :missing_house_id} = Offer.from_map(Map.delete(map, "house_id"))

    # The id reaches container labels and credential directory names.
    for bad <- ["", "another-house", "#{house}@x", "../#{house}"] do
      assert {:error, :invalid_house_id} = Offer.from_map(%{map | "house_id" => bad})
    end

    assert {:error, :missing_house_id} = Offer.from_map(%{map | "house_id" => 42})
  end

  test "carries the job's secret-scan policy: the house key and its allowances" do
    user = user_fixture()
    {token, _} = api_token_fixture(user)

    {job, attempt} =
      job_fixture(user, token, %{
        status: "provisioning",
        repository: nil,
        admitted_repository: nil,
        admitted_repository_digest: nil,
        environment: "notes",
        admitted_environment: %{"name" => "notes", "sink" => "files"}
      })

    allowed = String.duplicate("a", 64)
    other = String.duplicate("b", 64)

    Repo.insert!(%Omashiki.Jobs.SecretAllowance{
      fingerprint: allowed,
      environment: "notes",
      file: "notes.txt",
      rule_id: "github-pat"
    })

    Repo.insert!(%Omashiki.Jobs.SecretAllowance{
      fingerprint: other,
      environment: "code",
      repository: "app",
      file: "notes.txt",
      rule_id: "github-pat"
    })

    offer = Offer.from_claimed(job, attempt)
    assert offer.secret_scan.allowed == [allowed]
    assert byte_size(offer.secret_scan.key) == 32
    refute inspect(offer) =~ Base.encode64(offer.secret_scan.key)

    map = Offer.to_map(%{offer | house_id: Ecto.UUID.generate()})
    assert {:ok, round} = Offer.from_map(map)
    assert round.secret_scan == offer.secret_scan

    assert {:error, :invalid_secret_scan} = Offer.from_map(Map.delete(map, "secret_scan"))

    assert {:error, :invalid_secret_scan} =
             Offer.from_map(put_in(map, ["secret_scan", "key"], "short"))
  end
end
