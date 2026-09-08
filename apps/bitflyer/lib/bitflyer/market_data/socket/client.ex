defmodule Bitflyer.MarketData.Socket.Client do
  @moduledoc """
  市場データ WebSocket の契約。

  `start/1` は呼び出し元（Feed）と link する実装にすること。
  Feed は `trap_exit` で切断を受け取り、終了時に socket を道連れにする。

  実装は接続後に `feed` へ次を送る:
  - `:socket_connected`
  - `{:socket_frame, binary()}`
  - `{:socket_disconnected, reason}`
  """

  @callback start(keyword()) :: GenServer.on_start()
  @callback subscribe(pid_or_name :: term(), channel :: String.t()) :: :ok | {:error, term()}
end
