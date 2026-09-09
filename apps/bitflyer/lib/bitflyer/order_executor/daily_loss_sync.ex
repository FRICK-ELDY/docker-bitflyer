defmodule Bitflyer.OrderExecutor.DailyLossSync do
  @moduledoc false

  alias Bitflyer.Risk.DailyLoss

  @doc """
  Fill 反映の前後で DailyLoss を fail-closed に保つ。

  1. invalidate（世代トークン取得）
  2. 呼び出し側が DB トランザクションを実行
  3. 成功/失敗/例外いずれでも `release_barrier: true` の reload
  """
  @spec around_fill(DailyLoss.trade_mode(), (-> result)) :: result
        when result: {:ok, term()} | {:error, atom(), map()}
  def around_fill(trade_mode, fun) when is_function(fun, 0) do
    {:ok, generation} = DailyLoss.invalidate(trade_mode)

    result =
      try do
        fun.()
      catch
        kind, reason ->
          {:caught, kind, reason}
      end

    _ = release_reload(trade_mode, generation)

    case result do
      {:ok, _} = ok ->
        ok

      {:error, _, _} = error ->
        error

      {:caught, kind, reason} ->
        Bitflyer.Telemetry.log(
          :error,
          "fill aborted after daily loss invalidate; barrier released",
          %{trade_mode: trade_mode, kind: kind, reason: inspect(reason)}
        )

        {:error, :fill_aborted, %{kind: kind, reason: reason}}
    end
  end

  defp release_reload(trade_mode, generation) do
    case DailyLoss.reload(
           trade_mode: trade_mode,
           generation: generation,
           release_barrier: true
         ) do
      :ok ->
        :ok

      {:ok, :deferred} ->
        Bitflyer.Telemetry.log(
          :info,
          "daily loss reload after fill deferred; authorize stays unsynced until barriers clear",
          %{trade_mode: trade_mode}
        )

        {:ok, :deferred}

      {:error, reason} = error ->
        Bitflyer.Telemetry.log(
          :error,
          "daily loss reload after fill failed; authorize stays unsynced",
          %{trade_mode: trade_mode, reason: inspect(reason)}
        )

        error
    end
  end
end
