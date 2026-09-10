defmodule Bitflyer.Trading.Order do
  @moduledoc """
  内部注文の永続記録。

  `internal_order_id` は冪等キー（DB 一意）。取引所注文 ID との対応、
  未約定・部分約定の状態を復元可能にする。
  """
  use Ash.Resource,
    otp_app: :bitflyer,
    domain: Bitflyer.Trading,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "orders"
    repo Bitflyer.Repo

    custom_indexes do
      index [:exchange_order_id], name: "orders_exchange_order_id_index"
      index [:inserted_at], name: "orders_inserted_at_index"

      index [:strategy_parameter_revision_id],
        name: "orders_strategy_parameter_revision_id_index"
    end
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :internal_order_id,
        :exchange_order_id,
        :product_code,
        :side,
        :status,
        :order_type,
        :price,
        :size,
        :filled_size,
        :filled_notional,
        :trade_mode,
        :strategy_parameter_revision_id,
        :strategy_module,
        :command_hash
      ],
      update: [
        :exchange_order_id,
        :status,
        :price,
        :size,
        :filled_size,
        :filled_notional
      ]
    ]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :internal_order_id, :string do
      allow_nil? false
      public? true
    end

    attribute :exchange_order_id, :string do
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

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending

      constraints one_of: [
                    :pending,
                    :partially_filled,
                    :filled,
                    :cancelled,
                    :rejected,
                    :expired,
                    # 取引所へ送ったか不明（timeout / 切断等）。再送禁止・halt 前提
                    :submission_unknown
                  ]
    end

    attribute :order_type, :atom do
      allow_nil? false
      public? true
      default :limit
      constraints one_of: [:limit, :market]
    end

    attribute :price, :decimal do
      allow_nil? true
      public? true
    end

    attribute :size, :decimal do
      allow_nil? false
      public? true
      constraints greater_than: 0
    end

    attribute :filled_size, :decimal do
      allow_nil? false
      public? true
      default Decimal.new("0")
      constraints min: 0
    end

    # 取引所累積約定金額の baseline（remote_avg × remote_filled）。
    # Fill 行の Σ(price×size) とは丸め差で一致しないことがある。
    attribute :filled_notional, :decimal do
      allow_nil? false
      public? true
      default Decimal.new("0")
      constraints min: 0
    end

    attribute :trade_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:dry_run, :paper, :live]
    end

    # 戦略由来（任意）。人手・テスト経路の注文は nil のまま。
    attribute :strategy_parameter_revision_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :strategy_module, :string do
      allow_nil? true
      public? true
    end

    attribute :command_hash, :string do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  validations do
    validate present(:price), where: [attribute_equals(:order_type, :limit)]
    # 成行は発注時 price なし。約定後は fill 価格を price に残してよい
    validate absent(:price),
      where: [attribute_equals(:order_type, :market), attribute_equals(:status, :pending)]

    validate compare(:filled_size, less_than_or_equal_to: :size)
  end

  identities do
    identity :unique_internal_order_id, [:internal_order_id]

    # nil は複数可（未割当）。live/paper で同一 acceptance id の二重紐付けを防ぐ。
    identity :unique_exchange_order_id, [:trade_mode, :exchange_order_id], nils_distinct?: true
  end
end
