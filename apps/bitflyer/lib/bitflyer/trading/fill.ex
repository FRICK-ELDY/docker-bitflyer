defmodule Bitflyer.Trading.Fill do
  @moduledoc """
  約定明細の正本。

  建玉反映と同一トランザクションで 1 行ずつ残す。
  `realized_pnl` は決済の売買差から `fee` を引いた net（建増しも手数料だけ負）。
  日次損失・Equity・Status はここから集計する。

  live の `fee` は getexecutions の `commission`（spot は quote 通貨。BTC_JPY は JPY）。
  欠落は記帳しない（Decode fail-closed）。paper は価格に fee を載せるため `fee` は 0。
  本変更以前の行は `fee` が NULL（未記録）。残高説明は NULL 行だけ bps 許容を残す。

  live は取引所 execution 単位で書き、`(trade_mode, exchange_execution_id)` で二重記帳を拒む。
  paper は `exchange_execution_id` を nil のまま残す（一意制約の対象外）。

  本変更以前の live Fill は id=nil のまま残りうる。`LiveFills` はそうした baseline 上の
  **追加約定**を `:legacy_nil_execution_id` で拒否する（誤った再記帳より fail-closed）。
  デプロイ前に open live 注文へぶら下がる nil id Fill がゼロか確認すること
  （Gate は失敗後も間隔内 `:skip` しうるため、legacy 恒久失敗を残したまま live を上げない）:

      SELECT count(*)
      FROM fills f
      JOIN orders o ON o.internal_order_id = f.internal_order_id AND o.trade_mode = f.trade_mode
      WHERE f.trade_mode = 'live'
        AND f.exchange_execution_id IS NULL
        AND o.status IN ('pending', 'partially_filled');
  """
  use Ash.Resource,
    otp_app: :bitflyer,
    domain: Bitflyer.Trading,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "fills"
    repo Bitflyer.Repo

    custom_indexes do
      index [:trade_mode, :filled_at], name: "fills_trade_mode_filled_at_index"
      index [:internal_order_id], name: "fills_internal_order_id_index"
      index [:order_id], name: "fills_order_id_index"
    end
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :internal_order_id,
        :order_id,
        :exchange_execution_id,
        :product_code,
        :side,
        :size,
        :price,
        :realized_pnl,
        :fee,
        :trade_mode,
        :filled_at
      ]
    ]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :internal_order_id, :string do
      allow_nil? false
      public? true
    end

    attribute :order_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :exchange_execution_id, :string do
      allow_nil? true
      public? true
    end

    attribute :product_code, :string do
      allow_nil? false
      public? true
    end

    attribute :side, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:buy, :sell]
    end

    attribute :size, :decimal do
      allow_nil? false
      public? true
      constraints greater_than: 0
    end

    attribute :price, :decimal do
      allow_nil? false
      public? true
      constraints greater_than: 0
    end

    attribute :realized_pnl, :decimal do
      allow_nil? false
      public? true
      default Decimal.new("0")
    end

    # NULL = 未記録（レガシー）。0 は記録済みの無料。
    attribute :fee, :decimal do
      allow_nil? true
      public? true
      constraints min: 0
    end

    attribute :trade_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:dry_run, :paper, :live]
    end

    attribute :filled_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # nil は複数可（paper）。live の同一 execution 二重 Fill を DB が拒否する。
    identity :unique_trade_mode_exchange_execution_id, [:trade_mode, :exchange_execution_id],
      nils_distinct?: true
  end
end
