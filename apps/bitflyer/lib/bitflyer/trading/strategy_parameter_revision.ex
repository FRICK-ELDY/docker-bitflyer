defmodule Bitflyer.Trading.StrategyParameterRevision do
  @moduledoc """
  戦略パラメータ適用履歴（immutable・destroy なし）。

  起動時に実効設定を 1 行残す。同 `(trade_mode, params_hash)` があれば再利用する。
  注文経路のホットパスからは create しない（Architecture: Ash は永続のみ）。
  """
  use Ash.Resource,
    otp_app: :bitflyer,
    domain: Bitflyer.Trading,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "strategy_parameter_revisions"
    repo Bitflyer.Repo

    custom_indexes do
      index [:trade_mode, :applied_at],
        name: "strategy_parameter_revisions_trade_mode_applied_at_index"
    end

    identity_index_names unique_trade_mode_params_hash: "spr_trade_mode_params_hash_index"
  end

  actions do
    defaults [
      :read,
      create: [
        :trade_mode,
        :strategy_module,
        :params,
        :params_hash,
        :throttle_ms,
        :source,
        :operator,
        :applied_at
      ]
    ]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :trade_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:dry_run, :paper, :live]
    end

    attribute :strategy_module, :string do
      allow_nil? false
      public? true
    end

    attribute :params, :map do
      allow_nil? false
      public? true
    end

    attribute :params_hash, :string do
      allow_nil? false
      public? true
    end

    attribute :throttle_ms, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:boot, :ops]
    end

    attribute :operator, :string do
      allow_nil? false
      public? true
    end

    attribute :applied_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_trade_mode_params_hash, [:trade_mode, :params_hash]
  end
end
