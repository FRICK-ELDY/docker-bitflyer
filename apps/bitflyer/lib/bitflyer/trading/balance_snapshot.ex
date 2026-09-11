defmodule Bitflyer.Trading.BalanceSnapshot do
  @moduledoc """
  残高の時点スナップショット。

  直近行が起動突合・BalanceCache の基準になる。金額は Decimal。
  append-only のため、先端取得は `latest_tips/1`（DISTINCT ON）を使う。
  インデックスは `latest_tips` の ORDER BY（currency ASC, captured_at/id DESC）に揃え、
  filesort を避ける。
  """
  use Ash.Resource,
    otp_app: :bitflyer,
    domain: Bitflyer.Trading,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "balance_snapshots"
    repo Bitflyer.Repo

    custom_indexes do
      # DISTINCT ON (currency) ORDER BY currency ASC, captured_at DESC, id DESC と一致
      index [:trade_mode, :currency, {:desc, :captured_at}, {:desc, :id}],
        name: "balance_snapshots_latest_tips_index"
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

  validations do
    validate compare(:available, less_than_or_equal_to: :amount)
  end

  @doc """
  `trade_mode` 配下の通貨ごと最新 1 行。

  `DISTINCT ON (currency)` + `captured_at/id DESC`。
  索引 `balance_snapshots_latest_tips_index` とソート順を一致させる。
  接続・Postgrex 障害のみ `{:error, _}` に倒し、プログラミングエラーは rescue しない。
  クエリ／キュータイムアウトは `DBConnection.ConnectionError`（`:queue_timeout` 等）として上がる
  （`DBConnection.TimeoutError` は現行 db_connection に存在しない）。
  """
  @spec latest_tips(atom()) :: {:ok, [struct()]} | {:error, term()}
  def latest_tips(trade_mode) when trade_mode in [:dry_run, :paper, :live] do
    import Ecto.Query

    query =
      from(b in __MODULE__,
        where: b.trade_mode == ^trade_mode,
        distinct: b.currency,
        order_by: [asc: b.currency, desc: b.captured_at, desc: b.id]
      )

    {:ok, Bitflyer.Repo.all(query)}
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, e}
  end

  @doc """
  tip 行リストを `%{currency => available}` に畳む。
  """
  @spec available_map([struct()]) :: %{optional(String.t()) => Decimal.t()}
  def available_map(rows) when is_list(rows) do
    Map.new(rows, fn row -> {row.currency, row.available || row.amount} end)
  end
end
