defmodule Bitflyer.Exchange do
  @moduledoc """
  取引所アダプタの入口。実装は `:exchange_client` で差し替える。
  """

  alias Bitflyer.Exchange.Client

  @doc """
  突合用スナップショットを取得する。
  """
  @spec fetch_reconcile_snapshot() :: {:ok, Client.snapshot()} | {:error, term()}
  def fetch_reconcile_snapshot do
    client().fetch_reconcile_snapshot()
  end

  defp client do
    Application.get_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
  end
end
