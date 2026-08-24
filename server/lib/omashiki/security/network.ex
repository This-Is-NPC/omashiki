defmodule Omashiki.Security.Network do
  @moduledoc "Fail-closed checks for network destinations used by job data planes."

  import Bitwise

  @doc "Allow a hostname only when its known addresses are not private or reserved."
  def authorize_host(host, opts \\ [])

  def authorize_host(host, opts) when is_binary(host) and host != "" do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        if public_address?(address), do: :ok, else: {:error, :restricted_destination}

      {:error, _} ->
        resolver = Keyword.get(opts, :resolver, &resolve/1)

        case resolver.(host) do
          {:ok, addresses} when is_list(addresses) and addresses != [] ->
            if Enum.all?(addresses, &public_address?/1),
              do: :ok,
              else: {:error, :restricted_destination}

          _ ->
            {:error, :unresolved_destination}
        end
    end
  end

  def authorize_host(_, _), do: {:error, :invalid_destination_host}

  @doc false
  def public_address?({a, b, c, d})
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    not (a == 0 or
           a == 10 or
           a == 127 or
           (a == 169 and b == 254) or
           (a == 172 and b in 16..31) or
           (a == 192 and b == 168) or
           (a == 100 and b in 64..127) or
           (a == 192 and b == 0) or
           (a == 192 and b == 88 and c == 99) or
           (a == 198 and b in 18..19) or
           (a == 198 and b == 51 and c == 100) or
           (a == 203 and b == 0 and c == 113) or
           a >= 224) and is_integer(d)
  end

  def public_address?({a, b, c, d, e, f, g, h})
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) and
             is_integer(e) and is_integer(f) and is_integer(g) and is_integer(h) do
    cond do
      {a, b, c, d, e, f, g, h} == {0, 0, 0, 0, 0, 0, 0, 1} ->
        false

      {a, b, c, d, e, f, g, h} == {0, 0, 0, 0, 0, 0, 0, 0} ->
        false

      (a &&& 0xFE00) == 0xFC00 ->
        false

      (a &&& 0xFFC0) == 0xFE80 ->
        false

      (a &&& 0xFF00) == 0xFF00 ->
        false

      a == 0x2001 and b in [0x2, 0xDB8] ->
        false

      {a, b, c, d, e, f} == {0, 0, 0, 0, 0, 0} ->
        false

      {a, b, c, d, e, f} == {0, 0, 0, 0, 0, 0xFFFF} ->
        public_address?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})

      true ->
        true
    end
  end

  def public_address?(_), do: false

  defp resolve(host) do
    addresses =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(String.to_charlist(host), family) do
          {:ok, values} -> values
          _ -> []
        end
      end)

    if addresses == [], do: {:error, :unresolved}, else: {:ok, Enum.uniq(addresses)}
  end
end
