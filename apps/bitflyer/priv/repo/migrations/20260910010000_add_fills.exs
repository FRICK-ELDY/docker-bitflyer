defmodule Bitflyer.Repo.Migrations.AddFills do
  @moduledoc """
  約定明細（日次損失の正本）。
  """

  use Ecto.Migration

  def up do
    create table(:fills, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:internal_order_id, :text, null: false)
      add(:exchange_execution_id, :text)
      add(:product_code, :text, null: false)
      add(:side, :text, null: false)
      add(:size, :decimal, null: false)
      add(:price, :decimal, null: false)
      add(:realized_pnl, :decimal, null: false, default: "0")
      add(:trade_mode, :text, null: false)
      add(:filled_at, :utc_datetime_usec, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create index(:fills, [:trade_mode, :filled_at], name: "fills_trade_mode_filled_at_index")
    create index(:fills, [:internal_order_id], name: "fills_internal_order_id_index")
  end

  def down do
    drop_if_exists(index(:fills, [:internal_order_id], name: "fills_internal_order_id_index"))

    drop_if_exists(
      index(:fills, [:trade_mode, :filled_at], name: "fills_trade_mode_filled_at_index")
    )

    drop(table(:fills))
  end
end
