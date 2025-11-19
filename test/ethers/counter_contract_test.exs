defmodule Ethers.Contract.Test.CounterContract do
  @moduledoc false
  use Ethers.Contract, abi_file: "tmp/counter_abi.json"
end

defmodule Ethers.CounterContractTest do
  use ExUnit.Case
  doctest Ethers.Contract

  import Ethers.TestHelpers

  alias Ethers.Event
  alias Ethers.Utils

  alias Ethers.Contract.Test.CounterContract

  @from "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  @from_private_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  describe "contract deployment" do
    test "Can deploy a contract on blockchain" do
      encoded_constructor = CounterContract.constructor(100)

      assert {:ok, tx_hash} =
               Ethers.deploy(CounterContract,
                 encoded_constructor: encoded_constructor,
                 from: @from
               )

      wait_for_transaction!(tx_hash)

      assert {:ok, _address} = Ethers.deployed_address(tx_hash)
    end

    test "Can deploy a contract with local signer" do
      encoded_constructor = CounterContract.constructor(100)

      assert {:ok, tx_hash} =
               Ethers.deploy(CounterContract,
                 encoded_constructor: encoded_constructor,
                 from: @from,
                 signer: Ethers.Signer.Local,
                 signer_opts: [private_key: @from_private_key]
               )

      wait_for_transaction!(tx_hash)

      assert {:ok, address} = Ethers.deployed_address(tx_hash)
      assert {:ok, 100} = CounterContract.get() |> Ethers.call(to: address)
    end
  end

  describe "inspecting function calls" do
    test "renders the correct values when inspected" do
      assert "#Ethers.TxData<function get() view returns (uint256 amount)>" ==
               inspect(CounterContract.get())

      assert "#Ethers.TxData<function getNoReturnName() view returns (uint256)>" ==
               inspect(CounterContract.get_no_return_name())

      assert "#Ethers.TxData<function set(uint256 newAmount 101) non_payable>" ==
               inspect(CounterContract.set(101))
    end

    test "shows unknown state mutability correctly" do
      tx_data = CounterContract.get()

      assert "#Ethers.TxData<function get() unknown returns (uint256 amount)>" ==
               inspect(put_in(tx_data.selector.state_mutability, nil))
    end

    test "skips argument names in case of length mismatch" do
      tx_data = CounterContract.set(101)

      assert "#Ethers.TxData<function set(uint256 101) non_payable>" ==
               inspect(put_in(tx_data.selector.input_names, ["invalid", "names", "length"]))
    end

    test "includes default address if given" do
      tx_data = CounterContract.get()

      tx_data_with_default_address = %{tx_data | default_address: @from}

      assert ~s'#Ethers.TxData<function get() view returns (uint256 amount)\n  default_address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266">' ==
               inspect(tx_data_with_default_address)
    end
  end

  describe "inspecting event filters" do
    test "renders the correct values when inspected" do
      assert "#Ethers.EventFilter<event SetCalled(uint256 indexed oldAmount any, uint256 newAmount)>" ==
               inspect(CounterContract.EventFilters.set_called(nil))

      assert "#Ethers.EventFilter<event SetCalled(uint256 indexed oldAmount 101, uint256 newAmount)>" ==
               inspect(CounterContract.EventFilters.set_called(101))
    end

    test "renders the correct values when input names are not provided or incorrect" do
      filter = CounterContract.EventFilters.set_called(101)

      assert "#Ethers.EventFilter<event SetCalled(uint256 indexed 101, uint256)>" ==
               inspect(put_in(filter.selector.input_names, []))

      assert "#Ethers.EventFilter<event SetCalled(uint256 indexed 101, uint256)>" ==
               inspect(
                 put_in(filter.selector.input_names, filter.selector.input_names ++ ["invalid"])
               )
    end

    test "includes default address if given" do
      filter = CounterContract.EventFilters.set_called(101)

      filter_with_default_address = %{filter | default_address: @from}

      assert ~s'#Ethers.EventFilter<event SetCalled(uint256 indexed oldAmount 101, uint256 newAmount)\n  default_address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266">' ==
               inspect(filter_with_default_address)
    end
  end

  describe "calling functions" do
    setup :deploy_counter_contract

    test "calling view functions", %{address: address} do
      assert %Ethers.TxData{
               base_module: CounterContract,
               data: Utils.hex_decode!("0x6d4ce63c"),
               selector: %ABI.FunctionSelector{
                 function: "get",
                 method_id: <<109, 76, 230, 60>>,
                 type: :function,
                 inputs_indexed: nil,
                 state_mutability: :view,
                 input_names: [],
                 types: [],
                 returns: [uint: 256],
                 return_names: ["amount"]
               },
               default_address: nil
             } == CounterContract.get()

      assert {:ok, 100} = CounterContract.get() |> Ethers.call(to: address)
      assert 100 = CounterContract.get() |> Ethers.call!(to: address)
    end

    test "sending transaction with state mutating functions", %{address: address} do
      {:ok, tx_hash} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash)

      {:ok, 101} = CounterContract.get() |> Ethers.call(to: address)
    end

    test "sending transaction with state mutating functions using bang functions", %{
      address: address
    } do
      tx_hash = CounterContract.set(101) |> Ethers.send_transaction!(from: @from, to: address)

      wait_for_transaction!(tx_hash)

      assert 101 == CounterContract.get() |> Ethers.call!(to: address)
    end

    test "returns error if to address is not given" do
      assert {:error, :no_to_address} = CounterContract.get() |> Ethers.call()

      assert {:error, :no_to_address} =
               CounterContract.set(101) |> Ethers.send_transaction(from: @from)

      assert {:error, :no_to_address} =
               CounterContract.set(101) |> Ethers.send_transaction(from: @from, gas: 100)

      assert {:error, :no_to_address} = CounterContract.set(101) |> Ethers.send_transaction()

      assert {:error, :no_to_address} =
               CounterContract.set(101) |> Ethers.estimate_gas(from: @from, gas: 100)
    end

    test "raises if to address is not given using the bang functions" do
      assert_raise Ethers.ExecutionError, "Unexpected error: no_to_address", fn ->
        CounterContract.get() |> Ethers.call!()
      end

      assert_raise Ethers.ExecutionError, "Unexpected error: no_to_address", fn ->
        CounterContract.set(101) |> Ethers.send_transaction!(from: @from)
      end

      assert_raise Ethers.ExecutionError, "Unexpected error: no_to_address", fn ->
        CounterContract.set(101) |> Ethers.send_transaction!(from: @from, gas: 100)
      end

      assert_raise Ethers.ExecutionError, "Unexpected error: no_to_address", fn ->
        CounterContract.set(101) |> Ethers.estimate_gas!(from: @from, gas: 100)
      end
    end

    test "returns the gas estimate with Ethers.estimate_gas", %{address: address} do
      assert {:ok, gas_estimate} =
               CounterContract.set(101) |> Ethers.estimate_gas(from: @from, to: address)

      assert is_integer(gas_estimate)

      # Same with the bang function
      assert ^gas_estimate =
               CounterContract.set(101) |> Ethers.estimate_gas!(from: @from, to: address)
    end

    test "returns the params when called" do
      assert %Ethers.TxData{
               base_module: CounterContract,
               data:
                 Utils.hex_decode!(
                   "0x60fe47b10000000000000000000000000000000000000000000000000000000000000065"
                 ),
               selector: %ABI.FunctionSelector{
                 function: "set",
                 method_id: <<96, 254, 71, 177>>,
                 type: :function,
                 inputs_indexed: nil,
                 state_mutability: :non_payable,
                 input_names: ["newAmount"],
                 types: [uint: 256],
                 returns: []
               },
               default_address: nil
             } == CounterContract.set(101)
    end
  end

  describe "Event filter works with get_logs" do
    setup :deploy_counter_contract

    test "can get the emitted event with the correct filter", %{address: address} do
      {:ok, tx_hash} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash)

      assert open_filter = CounterContract.EventFilters.set_called(nil)
      assert correct_filter = CounterContract.EventFilters.set_called(100)
      assert incorrect_filter = CounterContract.EventFilters.set_called(105)

      assert {:ok,
              [
                %Event{
                  address: ^address,
                  topics: ["SetCalled(uint256,uint256)", 100],
                  data: [101]
                }
              ]} = Ethers.get_logs(open_filter)

      assert {:ok, [%Event{address: ^address, data: [101]}]} = Ethers.get_logs(correct_filter)
      assert {:ok, []} = Ethers.get_logs(incorrect_filter)
    end

    test "cat get the emitted events with get_logs! function", %{address: address} do
      {:ok, tx_hash} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash)

      assert filter = CounterContract.EventFilters.set_called(nil)

      assert [
               %Ethers.Event{
                 address: ^address,
                 topics: ["SetCalled(uint256,uint256)", 100],
                 data: [101],
                 data_raw: "0x0000000000000000000000000000000000000000000000000000000000000065",
                 log_index: 0,
                 removed: false,
                 topics_raw: [
                   "0x9db4e91e99652c2cf1713076f100fca6a4f5b81f166bce406ff2b3012694f49f",
                   "0x0000000000000000000000000000000000000000000000000000000000000064"
                 ],
                 transaction_hash: ^tx_hash,
                 transaction_index: 0,
                 block_hash: block_hash,
                 block_number: block_number
               }
             ] = Ethers.get_logs!(filter)

      assert is_integer(block_number)
      assert String.valid?(block_hash)
    end

    test "can filter logs with from_block and to_block options", %{address: address} do
      {:ok, tx_hash} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash)

      assert filter = CounterContract.EventFilters.set_called(nil)

      {:ok, current_block_number} = Ethers.current_block_number()

      assert [] ==
               Ethers.get_logs!(filter,
                 from_block: current_block_number - 1,
                 to_block: current_block_number - 1
               )

      assert [
               %Ethers.Event{
                 address: ^address,
                 topics: ["SetCalled(uint256,uint256)", 100],
                 data: [101],
                 data_raw: "0x0000000000000000000000000000000000000000000000000000000000000065",
                 log_index: 0,
                 removed: false,
                 topics_raw: [
                   "0x9db4e91e99652c2cf1713076f100fca6a4f5b81f166bce406ff2b3012694f49f",
                   "0x0000000000000000000000000000000000000000000000000000000000000064"
                 ],
                 transaction_hash: ^tx_hash,
                 transaction_index: 0
               }
             ] =
               Ethers.get_logs!(filter,
                 from_block: current_block_number - 1,
                 to_block: current_block_number
               )
    end
  end

  describe "get_logs_for_contract works with all events" do
    setup :deploy_counter_contract

    test "can get all events from the contract", %{address: address} do
      {:ok, tx_hash_1} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash_1)

      {:ok, tx_hash_2} =
        CounterContract.reset() |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash_2)

      {:ok, current_block_number} = Ethers.current_block_number()

      assert {:ok, events} =
               Ethers.get_logs_for_contract(CounterContract.EventFilters, address,
                 from_block: current_block_number - 2,
                 to_block: current_block_number
               )

      assert length(events) == 2

      [set_called_event, reset_called_event] = events

      assert %Event{
               address: ^address,
               topics: ["SetCalled(uint256,uint256)", 100],
               data: [101]
             } = set_called_event

      assert %Event{
               address: ^address,
               topics: ["ResetCalled()"],
               data: []
             } = reset_called_event
    end

    test "can get all events with get_logs_for_contract! function", %{address: address} do
      {:ok, tx_hash_1} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash_1)

      {:ok, tx_hash_2} =
        CounterContract.reset() |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash_2)

      {:ok, current_block_number} = Ethers.current_block_number()

      events =
        Ethers.get_logs_for_contract!(CounterContract.EventFilters, address,
          from_block: current_block_number - 2,
          to_block: current_block_number
        )

      assert [
               %Ethers.Event{
                 address: ^address,
                 topics: ["SetCalled(uint256,uint256)", 100],
                 data: [101]
               },
               %Ethers.Event{
                 address: ^address,
                 topics: ["ResetCalled()"],
                 data: []
               }
             ] = events
    end

    test "can filter logs with from_block and to_block options", %{address: address} do
      {:ok, tx_hash_1} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash_1)

      {:ok, tx_hash_2} =
        CounterContract.reset() |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash_2)

      {:ok, current_block_number} = Ethers.current_block_number()

      assert [
               %Ethers.Event{
                 address: ^address,
                 topics: ["SetCalled(uint256,uint256)", 100],
                 data: [101],
                 data_raw: "0x0000000000000000000000000000000000000000000000000000000000000065",
                 log_index: 0,
                 removed: false,
                 transaction_hash: ^tx_hash_1,
                 transaction_index: 0
               }
             ] =
               Ethers.get_logs_for_contract!(CounterContract.EventFilters, address,
                 from_block: current_block_number - 1,
                 to_block: current_block_number - 1
               )
    end

    test "returns empty list for non-existent contract address" do
      fake_address = "0x1234567890123456789012345678901234567890"

      assert {:ok, []} =
               Ethers.get_logs_for_contract(CounterContract.EventFilters, fake_address)
    end
  end

  describe "override block number" do
    setup :deploy_counter_contract

    test "can call a view function on a previous block", %{address: address} do
      CounterContract.set(101)
      |> Ethers.send_transaction!(from: @from, to: address)
      |> wait_for_transaction!()

      {:ok, block_1} = Ethers.current_block_number()

      CounterContract.set(102)
      |> Ethers.send_transaction!(from: @from, to: address)
      |> wait_for_transaction!()

      {:ok, block_2} = Ethers.current_block_number()

      assert is_integer(block_2)

      CounterContract.set(103)
      |> Ethers.send_transaction!(from: @from, to: address)
      |> wait_for_transaction!()

      assert CounterContract.get() |> Ethers.call!(to: address, block: "latest") == 103
      assert CounterContract.get() |> Ethers.call!(to: address, block: block_2) == 102
      assert CounterContract.get() |> Ethers.call!(to: address, block: block_1) == 101
    end
  end

  describe "stream_logs_for_contract works with WebSocket" do
    setup :deploy_counter_contract
    setup :ensure_websocket_server

    test "can stream events from the contract in real-time", %{address: address} do
      # Start streaming
      {:ok, stream} =
        Ethers.stream_logs_for_contract(CounterContract.EventFilters, address, subscriber: self())

      # Give the subscription time to establish
      Process.sleep(100)

      # Trigger an event
      {:ok, tx_hash_1} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash_1)

      # Should receive the event
      assert_receive {:event,
                      %Event{
                        address: ^address,
                        topics: ["SetCalled(uint256,uint256)", 100],
                        data: [101]
                      }},
                     5_000

      # Trigger another event
      {:ok, tx_hash_2} =
        CounterContract.reset() |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash_2)

      # Should receive the second event
      assert_receive {:event,
                      %Event{
                        address: ^address,
                        topics: ["ResetCalled()"],
                        data: []
                      }},
                     5_000

      # Clean up
      Ethers.EventStream.stop(stream)
    end

    test "can stream multiple events in sequence", %{address: address} do
      {:ok, stream} =
        Ethers.stream_logs_for_contract(CounterContract.EventFilters, address, subscriber: self())

      Process.sleep(100)

      # Trigger multiple events
      for i <- 1..3 do
        {:ok, tx_hash} =
          CounterContract.set(100 + i) |> Ethers.send_transaction(from: @from, to: address)

        wait_for_transaction!(tx_hash)
      end

      # Should receive all 3 events
      events =
        for _i <- 1..3 do
          assert_receive {:event, event}, 5_000
          event
        end

      assert length(events) == 3

      # Verify event data is correct
      assert [
               %Event{data: [101]},
               %Event{data: [102]},
               %Event{data: [103]}
             ] = events

      Ethers.EventStream.stop(stream)
    end

    test "stream only receives events for specified address", %{address: address} do
      # Deploy a second contract
      encoded_constructor = CounterContract.constructor(200)
      address2 = deploy(CounterContract, encoded_constructor: encoded_constructor, from: @from)

      # Stream only from first contract
      {:ok, stream} =
        Ethers.stream_logs_for_contract(CounterContract.EventFilters, address, subscriber: self())

      Process.sleep(100)

      # Trigger event on second contract
      {:ok, tx_hash_2} =
        CounterContract.set(201) |> Ethers.send_transaction(from: @from, to: address2)

      wait_for_transaction!(tx_hash_2)

      # Trigger event on first contract
      {:ok, tx_hash_1} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash_1)

      # Should only receive event from first contract
      assert_receive {:event,
                      %Event{
                        address: ^address,
                        data: [101]
                      }},
                     5_000

      # Should not receive event from second contract
      refute_receive {:event, %Event{address: ^address2}}, 1_000

      Ethers.EventStream.stop(stream)
    end

    test "can have multiple concurrent streams", %{address: address} do
      # Deploy second contract
      encoded_constructor = CounterContract.constructor(200)
      address2 = deploy(CounterContract, encoded_constructor: encoded_constructor, from: @from)

      # Start two streams
      {:ok, stream1} =
        Ethers.stream_logs_for_contract(CounterContract.EventFilters, address, subscriber: self())

      {:ok, stream2} =
        Ethers.stream_logs_for_contract(CounterContract.EventFilters, address2,
          subscriber: self()
        )

      Process.sleep(100)

      # Trigger events on both contracts
      {:ok, tx_hash_1} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash_1)

      {:ok, tx_hash_2} =
        CounterContract.set(201) |> Ethers.send_transaction(from: @from, to: address2)

      wait_for_transaction!(tx_hash_2)

      # Should receive events from both contracts
      assert_receive {:event, %Event{address: ^address, data: [101]}}, 5_000
      assert_receive {:event, %Event{address: ^address2, data: [201]}}, 5_000

      Ethers.EventStream.stop(stream1)
      Ethers.EventStream.stop(stream2)
    end

    test "returns subscription ID", %{address: address} do
      {:ok, stream} =
        Ethers.stream_logs_for_contract(CounterContract.EventFilters, address, subscriber: self())

      Process.sleep(100)

      {:ok, subscription_id} = Ethers.EventStream.get_subscription_id(stream)
      assert is_binary(subscription_id)
      assert String.starts_with?(subscription_id, "0x")

      Ethers.EventStream.stop(stream)
    end

    test "handles stream with nil address (all contracts)", %{address: address} do
      # Stream from all contracts
      {:ok, stream} =
        Ethers.stream_logs_for_contract(CounterContract.EventFilters, nil, subscriber: self())

      Process.sleep(100)

      # Trigger event
      {:ok, tx_hash} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash)

      # Should still receive the event
      assert_receive {:event,
                      %Event{
                        address: ^address,
                        data: [101]
                      }},
                     5_000

      Ethers.EventStream.stop(stream)
    end

    test "stops receiving events after stream is stopped", %{address: address} do
      {:ok, stream} =
        Ethers.stream_logs_for_contract(CounterContract.EventFilters, address, subscriber: self())

      Process.sleep(100)

      # Stop the stream
      Ethers.EventStream.stop(stream)
      Process.sleep(100)

      # Trigger event after stopping
      {:ok, tx_hash} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash)

      # Should not receive the event
      refute_receive {:event, _}, 2_000
    end

    test "can filter by specific event using topics", %{address: address} do
      # Get only SetCalled events (not ResetCalled)
      set_called_topic = "0x9db4e91e99652c2cf1713076f100fca6a4f5b81f166bce406ff2b3012694f49f"

      {:ok, stream} =
        Ethers.stream_logs_for_contract(CounterContract.EventFilters, address,
          subscriber: self(),
          topics: [set_called_topic]
        )

      Process.sleep(100)

      # Trigger a SetCalled event
      {:ok, tx_hash_1} =
        CounterContract.set(101) |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash_1)

      # Should receive SetCalled event
      assert_receive {:event, %Event{topics: ["SetCalled(uint256,uint256)", 100], data: [101]}},
                     5_000

      # Trigger a ResetCalled event
      {:ok, tx_hash_2} =
        CounterContract.reset() |> Ethers.send_transaction(from: @from, to: address)

      wait_for_transaction!(tx_hash_2)

      # Should not receive ResetCalled event (filtered out)
      refute_receive {:event, %Event{topics: ["ResetCalled()"]}}, 1_000

      Ethers.EventStream.stop(stream)
    end
  end

  defp deploy_counter_contract(_ctx) do
    encoded_constructor = CounterContract.constructor(100)

    address = deploy(CounterContract, encoded_constructor: encoded_constructor, from: @from)

    [address: address]
  end

  defp ensure_websocket_server(_ctx) do
    case Process.whereis(Ethereumex.WebsocketServer) do
      nil ->
        # Start WebSocket server for testing
        # Uses the default config from config/test.exs
        {:ok, _pid} = Ethereumex.WebsocketServer.start_link()
        Process.sleep(500)
        :ok

      _pid ->
        :ok
    end

    :ok
  end
end
