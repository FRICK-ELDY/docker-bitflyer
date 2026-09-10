defmodule Bitflyer.Exchange.Unavailable do
  @moduledoc """
  取引所クライアント未接続時の既定実装。live 突合・発注・取消・照会は必ず失敗する。
  """

  @behaviour Bitflyer.Exchange.Client

  @impl true
  def fetch_reconcile_snapshot do
    {:error, :exchange_unavailable}
  end

  @impl true
  def place_order(_request) do
    {:error, :exchange_unavailable}
  end

  @impl true
  def cancel_order(_request) do
    {:error, :exchange_unavailable}
  end

  @impl true
  def fetch_order(_request) do
    {:error, :exchange_unavailable}
  end

  @impl true
  def list_child_orders(_request) do
    {:error, :exchange_unavailable}
  end

  @impl true
  def fetch_executions(_request) do
    {:error, :exchange_unavailable}
  end

  @impl true
  def get_permissions do
    {:error, :exchange_unavailable}
  end
end
