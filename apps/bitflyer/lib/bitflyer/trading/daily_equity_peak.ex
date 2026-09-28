defmodule Bitflyer.Trading.DailyEquityPeak do
  @moduledoc """
  当日 equity ピーク（HWM）の正本。

  `(trade_mode, trading_day)` で一意。`DailyLoss.record_peak/3` が上昇時、
  認可の write-behind（`PeakWriter`）、および `peak > persisted_peak` の flush 時に
  upsert する（認可のホットパスは ETS のみ。同期 persist は Fill 後 / 突合 / resume）。
  `DailyLoss` の init / reload / reinit が当日行を読む。無い行はピーク 0（日始）。
  """
  use Ash.Resource,
    otp_app: :bitflyer,
    domain: Bitflyer.Trading,
    data_layer: AshPostgres.DataLayer

  require Ash.Query

  postgres do
    table "daily_equity_peaks"
    repo Bitflyer.Repo

    custom_indexes do
      index [:trade_mode, :trading_day],
        unique: true,
        name: "daily_equity_peaks_unique_mode_day_index"
    end
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:trade_mode, :trading_day, :peak],
      update: [:peak]
    ]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :trade_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:dry_run, :paper, :live]
    end

    attribute :trading_day, :date do
      allow_nil? false
      public? true
    end

    attribute :peak, :decimal do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  validations do
    validate compare(:peak, greater_than_or_equal_to: 0)
  end

  identities do
    identity :unique_mode_day, [:trade_mode, :trading_day]
  end

  @doc """
  指定 JST 取引日のピーク行。読取失敗だけ `{:error, _}`。
  """
  @spec fetch_day(Date.t()) :: {:ok, [struct()]} | {:error, term()}
  def fetch_day(%Date{} = day) do
    case __MODULE__
         |> Ash.Query.filter(trading_day == ^day)
         |> Ash.read() do
      {:ok, rows} -> {:ok, rows}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  ピークが正のとき、単調な upsert を 1 文で書く。0 以下は何もしない。

  `INSERT ... ON CONFLICT DO UPDATE SET peak = GREATEST(...)` なので、
  並行した低い値は高い値を上書きしない（HWM は単調増加）。一意制約の
  衝突を文字列で拾って読み直す必要はない。`id` と時刻は文中で渡す。
  列 default は本番の Ash create では使わない。
  """
  @spec upsert(atom(), Date.t(), Decimal.t()) :: :ok | {:error, term()}
  def upsert(trade_mode, %Date{} = day, %Decimal{} = peak)
      when trade_mode in [:dry_run, :paper, :live] do
    if Decimal.compare(peak, 0) != :gt do
      :ok
    else
      do_upsert(trade_mode, day, peak)
    end
  end

  # AshPostgres 2.13 の upsert は PostgreSQL 17 で MERGE になる。MERGE は
  # 同じキーの並行 insert を待たず、敗者が一意制約で落ちる。HWM は
  # INSERT ... ON CONFLICT の 1 文で仲裁する。
  defp do_upsert(trade_mode, day, peak) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    sql = """
    INSERT INTO daily_equity_peaks (
      id, trade_mode, trading_day, peak, inserted_at, updated_at
    )
    VALUES ($1::uuid, $2, $3, $4, $5, $6)
    ON CONFLICT (trade_mode, trading_day)
    DO UPDATE SET
      peak = GREATEST(daily_equity_peaks.peak, EXCLUDED.peak),
      updated_at = CASE
        WHEN EXCLUDED.peak > daily_equity_peaks.peak THEN EXCLUDED.updated_at
        ELSE daily_equity_peaks.updated_at
      END
    """

    params = [
      Ash.UUIDv7.bingenerate(),
      Atom.to_string(trade_mode),
      day,
      peak,
      now,
      now
    ]

    case Bitflyer.Repo.query(sql, params) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
