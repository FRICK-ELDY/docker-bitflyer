defmodule Bitflyer.Repo.Migrations.AddOrdersUniqueExchangeOrderId do
  @moduledoc """
  (trade_mode, exchange_order_id) の一意制約。NULL は複数可。
  """

  use Ecto.Migration

  def up do
    create unique_index(:orders, [:trade_mode, :exchange_order_id],
             name: "orders_unique_exchange_order_id_index",
             where: "exchange_order_id IS NOT NULL"
           )
  end

  def down do
    drop_if_exists(
      unique_index(:orders, [:trade_mode, :exchange_order_id],
        name: "orders_unique_exchange_order_id_index"
      )
    )
  end
end
