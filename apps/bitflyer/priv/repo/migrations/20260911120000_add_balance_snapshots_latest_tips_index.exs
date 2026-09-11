defmodule Bitflyer.Repo.Migrations.AddBalanceSnapshotsLatestTipsIndex do
  @moduledoc """
  `BalanceSnapshot.latest_tips/1` の DISTINCT ON ソート順に合わせた複合索引。

  旧 ASC 索引は filesort を誘発しうるため置き換える。
  """

  use Ecto.Migration

  def up do
    drop_if_exists(
      index(:balance_snapshots, [:trade_mode, :currency, :captured_at],
        name: "balance_snapshots_trade_mode_currency_captured_at_index"
      )
    )

    create index(:balance_snapshots, [:trade_mode, :currency, desc: :captured_at, desc: :id],
             name: "balance_snapshots_latest_tips_index"
           )
  end

  def down do
    drop_if_exists(
      index(:balance_snapshots, [:trade_mode, :currency, desc: :captured_at, desc: :id],
        name: "balance_snapshots_latest_tips_index"
      )
    )

    create index(:balance_snapshots, [:trade_mode, :currency, :captured_at],
             name: "balance_snapshots_trade_mode_currency_captured_at_index"
           )
  end
end
