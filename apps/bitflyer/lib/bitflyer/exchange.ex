defmodule Bitflyer.Exchange do
  @moduledoc """
  取引所アダプタの入口。実装は `:exchange_client` で差し替える。

  資格情報は `Bitflyer.Exchange.Credentials`（`BITFLYER_API_KEY` / `BITFLYER_API_SECRET`）。
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

  defp client do
    Application.get_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
  end
end
