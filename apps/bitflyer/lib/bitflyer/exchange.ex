defmodule Bitflyer.Exchange do
  @moduledoc """
  取引所アダプタの入口。実装は `:exchange_client` で差し替える。

  資格情報は `Bitflyer.Exchange.Credentials`（`BITFLYER_API_KEY` / `BITFLYER_API_SECRET`）。
  署名付き REST は `Bitflyer.Exchange.Rest`（`TRADE_MODE=live` かつキーありで runtime が差し込む）。
  """

  alias Bitflyer.Exchange.Client

  @doc """
  突合用スナップショットを取得する。
  """
  @spec fetch_reconcile_snapshot() :: {:ok, Client.snapshot()} | {:error, term()}
  def fetch_reconcile_snapshot do
    client().fetch_reconcile_snapshot()
  end

  @doc """
  取引所へ発注する。live order-executor 以外から呼ばないこと。
  """
  @spec place_order(Client.place_order_request()) ::
          {:ok, Client.place_order_result()} | {:error, term()}
  def place_order(request) when is_map(request) do
    client().place_order(request)
  end

  @doc """
  取引所の注文を取消する。live order-executor 以外から呼ばないこと。
  """
  @spec cancel_order(Client.cancel_order_request()) :: :ok | {:error, term()}
  def cancel_order(request) when is_map(request) do
    client().cancel_order(request)
  end

  @doc """
  取引所の注文状態を照会する。
  """
  @spec fetch_order(Client.fetch_order_request()) :: {:ok, Client.order_info()} | {:error, term()}
  def fetch_order(request) when is_map(request) do
    client().fetch_order(request)
  end

  @doc """
  約定一覧を取得する（live 約定反映用）。
  """
  @spec fetch_executions(Client.fetch_executions_request()) ::
          {:ok, [Client.execution()]} | {:error, term()}
  def fetch_executions(request) when is_map(request) do
    client().fetch_executions(request)
  end

  defp client do
    Application.get_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
  end
end
