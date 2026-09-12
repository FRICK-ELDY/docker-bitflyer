defmodule Bitflyer.Trading.DailyEquityPeak do
  @moduledoc """
  当日 equity ピーク（HWM）の正本。

  `(trade_mode, trading_day)` で一意。`DailyLoss.record_peak/3` が上昇時だけ upsert する
  （認可は ETS のみ。Fill 後 / 突合 / resume が persist）。
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
  ピークが正で、既存より高いときだけ書く。0 や同値は何もしない。

  更新は `peak < 新値` の条件付きなので、並行 upsert で低い値が
  高い値を上書きしない（HWM は単調増加）。
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

  defp do_upsert(trade_mode, day, peak) do
    do_upsert(trade_mode, day, peak, false)
  end

  defp do_upsert(trade_mode, day, peak, retried?) do
    case __MODULE__
         |> Ash.Query.filter(trade_mode == ^trade_mode and trading_day == ^day)
         |> Ash.read_one() do
      {:ok, nil} ->
        create_peak(trade_mode, day, peak, retried?)

      {:ok, row} ->
        if Decimal.compare(peak, row.peak) == :gt do
          update_peak(row, peak)
        else
          :ok
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp create_peak(trade_mode, day, peak, retried?) do
    case __MODULE__
         |> Ash.Changeset.for_create(:create, %{
           trade_mode: trade_mode,
           trading_day: day,
           peak: peak
         })
         |> Ash.create() do
      {:ok, _} ->
        :ok

      {:error, error} ->
        # 同時 insert の一意制約だけ読み直す。Invalid 全体を再試行すると
        # 検証エラーで do_upsert が再帰し続ける。
        if not retried? and unique_mode_day_taken?(error) do
          do_upsert(trade_mode, day, peak, true)
        else
          {:error, error}
        end
    end
  end

  defp unique_mode_day_taken?(error) do
    unique_mode_day_name?(inspect(error)) or
      error |> error_leaves() |> Enum.any?(&identity_collision?/1)
  end

  defp identity_collision?(%{identity: :unique_mode_day}), do: true

  defp identity_collision?(%{vars: %{key: :unique_mode_day}}), do: true

  defp identity_collision?(%{constraint: constraint}) when is_binary(constraint) do
    unique_mode_day_name?(constraint)
  end

  defp identity_collision?(%{postgres: %{constraint: constraint}}) when is_binary(constraint) do
    unique_mode_day_name?(constraint)
  end

  defp identity_collision?(%{private_vars: vars}) when is_list(vars) do
    Enum.any?(vars, fn
      {:constraint, name} when is_binary(name) -> unique_mode_day_name?(name)
      _ -> false
    end)
  end

  defp identity_collision?(other) do
    other
    |> Exception.message()
    |> unique_mode_day_name?()
  rescue
    _ -> false
  end

  defp unique_mode_day_name?(text) when is_binary(text) do
    String.contains?(text, "unique_mode_day") or
      String.contains?(text, "daily_equity_peaks_unique_mode_day")
  end

  defp error_leaves(%{errors: errors}) when is_list(errors) do
    Enum.flat_map(errors, &error_leaves/1)
  end

  defp error_leaves(other), do: [other]

  defp update_peak(row, peak) do
    # 無条件 update だと 150 の直後に 120 が書き戻り、再起動後の drawdown が緩む。
    case __MODULE__
         |> Ash.Query.filter(id == ^row.id and peak < ^peak)
         |> Ash.bulk_update(:update, %{peak: peak}, return_errors?: true, stop_on_error?: true) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{status: :error, errors: errors} ->
        {:error, errors}

      other ->
        {:error, other}
    end
  end
end
