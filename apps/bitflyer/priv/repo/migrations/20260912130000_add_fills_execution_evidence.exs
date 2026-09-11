defmodule Bitflyer.Repo.Migrations.AddFillsExecutionEvidence do
  @moduledoc """
  P1 #8: Fill に Order FK と (trade_mode, exchange_execution_id) 部分一意制約。

  デプロイ前確認（open live のレガシー nil id Fill が残ると追加約定 sync が fail-closed。
  Gate 間隔 skip と組み合わさるため、該当行ゼロがデプロイ前提）:

      SELECT count(*)
      FROM fills f
      JOIN orders o ON o.internal_order_id = f.internal_order_id AND o.trade_mode = f.trade_mode
      WHERE f.trade_mode = 'live'
        AND f.exchange_execution_id IS NULL
        AND o.status IN ('pending', 'partially_filled');
  """

  use Ecto.Migration

  def up do
    alter table(:fills) do
      add :order_id, references(:orders, type: :binary_id, on_delete: :restrict), null: true
    end

    create index(:fills, [:order_id], name: "fills_order_id_index")

    create unique_index(:fills, [:trade_mode, :exchange_execution_id],
             name: "fills_unique_trade_mode_exchange_execution_id_index",
             where: "exchange_execution_id IS NOT NULL"
           )
  end

  def down do
    drop_if_exists(
      unique_index(:fills, [:trade_mode, :exchange_execution_id],
        name: "fills_unique_trade_mode_exchange_execution_id_index"
      )
    )

    drop_if_exists(index(:fills, [:order_id], name: "fills_order_id_index"))

    alter table(:fills) do
      remove :order_id
    end
  end
end
