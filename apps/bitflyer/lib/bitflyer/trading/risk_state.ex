defmodule Bitflyer.Trading.RiskState do
  @moduledoc """
  リスク停止状態の正本。

  `name` でスコープを一意にする（既定 `"default"`）。
  サーキットオープン時の停止理由を永続化し、再起動後も復元する。
  """
  use Ash.Resource,
    otp_app: :bitflyer,
    domain: Bitflyer.Trading,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "risk_states"
    repo Bitflyer.Repo
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:name, :halted, :reason, :halted_at],
      update: [:halted, :reason, :halted_at]
    ]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      default "default"
    end

    attribute :halted, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :reason, :string do
      allow_nil? true
      public? true
    end

    attribute :halted_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  validations do
    validate present(:reason), where: [attribute_equals(:halted, true)]
    validate present(:halted_at), where: [attribute_equals(:halted, true)]
    validate absent(:reason), where: [attribute_equals(:halted, false)]
    validate absent(:halted_at), where: [attribute_equals(:halted, false)]
  end

  identities do
    identity :unique_name, [:name]
  end
end
