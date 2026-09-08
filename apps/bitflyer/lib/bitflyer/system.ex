defmodule Bitflyer.System do
  @moduledoc """
  開発・稼働確認用の Domain。取引エンティティは置かない。
  """
  use Ash.Domain,
    otp_app: :bitflyer

  resources do
    resource Bitflyer.System.Heartbeat
  end

  @doc """
  Repo 経由で PostgreSQL に到達できるか確認する。
  """
  def check_database do
    case Ecto.Adapters.SQL.query(Bitflyer.Repo, "SELECT 1", []) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc """
  現在の取引モード（`dry_run` / `paper` / `live`）。
  """
  def trade_mode do
    Application.get_env(:bitflyer, :trade_mode, "dry_run")
  end
end
