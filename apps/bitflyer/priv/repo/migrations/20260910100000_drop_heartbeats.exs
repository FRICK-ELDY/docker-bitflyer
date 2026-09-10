defmodule Bitflyer.Repo.Migrations.DropHeartbeats do
  use Ecto.Migration

  def up do
    drop_if_exists table(:heartbeats)
  end

  def down do
    create table(:heartbeats, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:note, :text, null: false, default: "ok")

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end
  end
end
