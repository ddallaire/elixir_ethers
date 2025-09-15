defmodule Ethers.Contract.Test.LoggerContract do
  @moduledoc false
  use Ethers.Contract, abi_file: "tmp/logger_abi.json"
end

defmodule Ethers.LoggerContractTest do
  use ExUnit.Case
  doctest Ethers.Contract

  import Ethers.TestHelpers

  alias Ethers.Contract.Test.LoggerContract

  @from "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

  describe "get_logs_for_contract works with all anonymous events" do
    setup :deploy_logger_contract

    test "can get all events from the contract", %{address: address} do
      {:ok, tx_hash_1} =
        Ethers.send_transaction(%Ethers.TxData{selector: %{type: :function}, data: "0xd34db33f"},
          from: @from,
          to: address
        )

      wait_for_transaction!(tx_hash_1)

      {:ok, tx_hash_2} =
        Ethers.send_transaction(%Ethers.TxData{selector: %{type: :function}, data: "0xc0ffee"},
          from: @from,
          to: address
        )

      wait_for_transaction!(tx_hash_2)

      {:ok, current_block_number} = Ethers.current_block_number()

      assert {:ok, events} =
               Ethers.get_logs_for_contract(LoggerContract.EventFilters, address,
                 from_block: current_block_number - 10,
                 to_block: current_block_number
               )

      assert length(events) == 2
    end
  end

  defp deploy_logger_contract(_ctx) do
    encoded_constructor = LoggerContract.constructor()

    address = deploy(LoggerContract, encoded_constructor: encoded_constructor, from: @from)

    [address: address]
  end
end
