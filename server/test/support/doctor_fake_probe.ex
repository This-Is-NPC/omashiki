defmodule Omashiki.Doctor.FakeProbe do
  @moduledoc false
  # Answers every `Omashiki.Doctor.Probe` callback from the application env so
  # the answers reach the monitor's task too. An answer is a result, or a
  # function of the callback's arguments; anything unset answers `:ok`.
  # Tests using it must be `async: false`.

  @behaviour Omashiki.Doctor.Probe

  @key :doctor_fake_probe

  def set(answers) when is_map(answers), do: Application.put_env(:omashiki, @key, answers)
  def reset, do: Application.delete_env(:omashiki, @key)

  @impl true
  def runtime, do: answer(:runtime, [])
  @impl true
  def image(image), do: answer(:image, [image])
  @impl true
  def network(name), do: answer(:network, [name])
  @impl true
  def house(port), do: answer(:house, [port])
  @impl true
  def route(image, network, url), do: answer(:route, [image, network, url])
  @impl true
  def readable(origin), do: answer(:readable, [origin])
  @impl true
  def directory(path), do: answer(:directory, [path])
  @impl true
  def identity(identity), do: answer(:identity, [identity])

  defp answer(callback, args) do
    case Map.get(Application.get_env(:omashiki, @key, %{}), callback, :ok) do
      fun when is_function(fun) -> apply(fun, args)
      result -> result
    end
  end
end
