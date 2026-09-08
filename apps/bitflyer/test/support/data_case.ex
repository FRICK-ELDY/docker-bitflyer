defmodule Bitflyer.DataCase do
  @moduledoc """
  Ash / Repo を使うテストの CaseTemplate。

  各テストは SQL Sandbox で隔離する。
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Bitflyer.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Bitflyer.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Bitflyer.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
