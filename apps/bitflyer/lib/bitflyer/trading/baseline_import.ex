defmodule Bitflyer.Trading.BaselineImport do
  @moduledoc """
  live 初回 BalanceSnapshot baseline と承認付き rebaseline の監査行。

  snapshot hash・操作者・取り込み時点の残高 payload を残す。
  payload["kind"] は `"import"` または `"rebaseline"`。
  Ready にはしない（通常突合成功時のみ Ready）。
  """
  use Ash.Resource,
    otp_app: :bitflyer,
    domain: Bitflyer.Trading,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "baseline_imports"
    repo Bitflyer.Repo

    custom_indexes do
      index [:trade_mode, :imported_at], name: "baseline_imports_trade_mode_imported_at_index"
    end
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :trade_mode,
        :snapshot_hash,
        :operator,
        :imported_at,
        :payload
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

    attribute :snapshot_hash, :string do
      allow_nil? false
      public? true
    end

    attribute :operator, :string do
      allow_nil? false
      public? true
    end

    attribute :imported_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :payload, :map do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
