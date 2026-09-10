defmodule Bitflyer.Repo.Migrations.AddBaselineImports do
  @moduledoc """
  live 初回 baseline import の監査テーブル。
  """

  use Ecto.Migration

  def up do
    create table(:baseline_imports, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:trade_mode, :text, null: false)
      add(:snapshot_hash, :text, null: false)
      add(:operator, :text, null: false)
      add(:imported_at, :utc_datetime_usec, null: false)
      add(:payload, :map, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create index(:baseline_imports, [:trade_mode, :imported_at],
             name: "baseline_imports_trade_mode_imported_at_index"
           )
  end

  def down do
    drop_if_exists(
      index(:baseline_imports, [:trade_mode, :imported_at],
        name: "baseline_imports_trade_mode_imported_at_index"
      )
    )

    drop(table(:baseline_imports))
  end
end
