defmodule Omashiki.Runtime.ContainerEvents do
  @moduledoc """
  Container lifecycle on this node, as it happens: created, started, removed.

  `ContainerManager` publishes each event after the Docker call that caused it
  succeeds, so a subscriber sees a container the moment it exists instead of
  at the next census. Events are local to the node that ran the call; a worker
  forwards what they add up to through `Omashiki.Runtime.ContainerTracker`.
  """

  @topic "runtime:containers"
  @events [:created, :started, :removed]

  @type event :: %{
          event: :created | :started | :removed,
          id: String.t(),
          scope_id: String.t() | nil,
          at: DateTime.t()
        }

  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(Omashiki.PubSub, @topic)

  @doc "Announce `event` for `container_id`. Never fails the Docker operation."
  def publish(event, container_id, scope_id \\ nil)
      when event in @events and is_binary(container_id) do
    message =
      {:container_event,
       %{event: event, id: container_id, scope_id: scope_id, at: DateTime.utc_now()}}

    Phoenix.PubSub.broadcast(Omashiki.PubSub, @topic, message)
    :ok
  rescue
    # A unit test can drive a container operation without PubSub running.
    ArgumentError -> :ok
  end
end
