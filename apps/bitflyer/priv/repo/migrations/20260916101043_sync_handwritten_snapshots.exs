defmodule Bitflyer.Repo.Migrations.SyncHandwrittenSnapshots do
  @moduledoc """
  Ash resource_snapshots 同期のための **意図的 no-op migration。削除しないこと。**

  ## なぜ空か

  `mix ash.codegen sync_handwritten_snapshots` が出した DDL は、既に手書き
  migration で適用済み（`orders.filled_notional` / `strategy_parameter_revisions` /
  `balance_snapshots` tips index 等）。再実行すると破壊的になるため `up`/`down`
  は `:ok` のみ。

  ## なぜファイルを残すか

  - `schema_migrations` に版本が載る（開発 DB は既に適用済み）
  - 同名で snapshot JSON（`priv/resource_snapshots/.../2026091610104*.json`）と
    対になる証跡。snapshot だけ残してこのファイルを消すと、他環境の
    `mix ecto.migrate` / 履歴突合が紛らわしくなる
  - `mix ash.codegen --check` が通る条件は snapshot 側。migration 空でも
    **コミット必須**（snapshot とセット）

  空だからといって削除してよいファイルではない。
  """

  use Ecto.Migration

  def up, do: :ok
  def down, do: :ok
end
