defmodule Omashiki.Runtimes.CacheSnapshot do
  @moduledoc """
  Point-in-time host cache information used by the cache maintenance backend.

  `entries` contains only top-level children of the configured group. Keeping
  eviction at that boundary avoids deleting half of a package manager's
  internal index or lock structure.
  """

  @enforce_keys [:group, :host, :size_bytes, :max_size_mb, :captured_at]
  defstruct [
    :group,
    :host,
    :size_bytes,
    :max_size_mb,
    :last_accessed_at,
    :captured_at,
    entries: [],
    errors: [],
    active_leases: 0
  ]

  @type entry :: %{
          name: String.t(),
          path: String.t(),
          type: atom(),
          size_bytes: non_neg_integer(),
          last_accessed_at: DateTime.t() | nil,
          evictable?: boolean()
        }

  @type t :: %__MODULE__{
          group: String.t(),
          host: String.t(),
          size_bytes: non_neg_integer(),
          max_size_mb: pos_integer() | nil,
          last_accessed_at: DateTime.t() | nil,
          captured_at: DateTime.t(),
          entries: [entry()],
          errors: [term()],
          active_leases: non_neg_integer()
        }

  @doc "Returns the configured byte limit, or nil when the group is unlimited."
  def limit_bytes(%__MODULE__{max_size_mb: nil}), do: nil
  def limit_bytes(%__MODULE__{max_size_mb: mb}), do: mb * 1024 * 1024

  @doc "Classifies a cache access without exposing its host path or contents."
  def outcome(%__MODULE__{size_bytes: size}) when is_integer(size) and size > 0, do: :warm
  def outcome(%__MODULE__{}), do: :cold
end
