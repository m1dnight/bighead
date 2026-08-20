defmodule Mem0.Repo do
  use Ecto.Repo,
    otp_app: :mem0,
    adapter: Ecto.Adapters.Postgres
end
