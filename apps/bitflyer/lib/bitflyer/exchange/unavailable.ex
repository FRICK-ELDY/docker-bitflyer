defmodule Bitflyer.Exchange.Unavailable do
  @moduledoc """
  取引所クライアント未接続時の既定実装。live 突合は必ず失敗する。
  """

  @behaviour Bitflyer.Exchange.Client

  @impl true
  def fetch_reconcile_snapshot do
    {:error, :exchange_unavailable}
  end
end
