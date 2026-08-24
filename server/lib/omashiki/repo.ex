defmodule Omashiki.Repo do
  use Ecto.Repo,
    otp_app: :omashiki,
    adapter: Ecto.Adapters.Postgres
end
