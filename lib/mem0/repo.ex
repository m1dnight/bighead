defmodule Bighead.Repo do
  use Ecto.Repo,
    otp_app: :bighead,
    adapter: Ecto.Adapters.Postgres
end
