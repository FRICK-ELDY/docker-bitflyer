defmodule Bitflyer.Trading.BalanceSnapshot do
  @moduledoc """
  残高の時点スナップショット。

  直近行が起動突合の基準になる。金額は Decimal。
  """
  use Ash.Resource,
    otp_app: :bitflyer,
    domain: Bitflyer.Trading,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "balance_snapshots"
    repo Bitflyer.Repo

    custom_indexes do
      index [:trade_mode, :currency, :captured_at],
        name: "balance_snapshots_trade_mode_currency_captured_at_index"
    end
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:currency, :amount, :available, :captured_at, :trade_mode]
    ]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :currency, :string do
      allow_nil? false
      public? true
    end

    attribute :amount, :decimal do
      allow_nil? false
      public? true
    end

    attribute :available, :decimal do
      allow_nil? false
      public? true
    end

    attribute :captured_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :trade_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:dry_run, :paper, :live]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
