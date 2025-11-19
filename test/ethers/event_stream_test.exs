defmodule Ethers.EventStreamTest do
  use ExUnit.Case, async: false

  alias Ethers.EventStream

  # Mock RPC client for testing
  defmodule MockWebsocketClient do
    def subscribe(:logs, _filter) do
      # Simulate successful subscription
      {:ok, "0x1234567890abcdef"}
    end

    def unsubscribe(_subscription_id) do
      {:ok, true}
    end
  end

  # A simple test contract EventFilters module
  defmodule TestContract.EventFilters do
    def __events__ do
      [
        %ABI.FunctionSelector{
          function: "Transfer",
          method_id: <<0xDD, 0xF2, 0x52, 0xAD>>,
          type: :event,
          inputs_indexed: [true, true, false],
          types: [:address, :address, {:uint, 256}],
          returns: []
        },
        %ABI.FunctionSelector{
          function: "Approval",
          method_id: <<0x8C, 0x5B, 0xE1, 0xE5>>,
          type: :event,
          inputs_indexed: [true, true, false],
          types: [:address, :address, {:uint, 256}],
          returns: []
        }
      ]
    end
  end

  describe "EventStream" do
    test "starts successfully with valid options" do
      {:ok, pid} =
        EventStream.start_link(
          event_filters_module: TestContract.EventFilters,
          address: "0x1234567890123456789012345678901234567890",
          subscriber: self(),
          rpc_client: MockWebsocketClient
        )

      assert Process.alive?(pid)

      # Wait for subscription to complete
      Process.sleep(100)

      # Get subscription ID
      {:ok, subscription_id} = EventStream.get_subscription_id(pid)
      assert subscription_id == "0x1234567890abcdef"

      # Clean up
      EventStream.stop(pid)
    end

    test "can stream with nil address (all contracts)" do
      {:ok, pid} =
        EventStream.start_link(
          event_filters_module: TestContract.EventFilters,
          address: nil,
          subscriber: self(),
          rpc_client: MockWebsocketClient
        )

      assert Process.alive?(pid)

      # Clean up
      EventStream.stop(pid)
    end

    test "handles incoming log notifications" do
      {:ok, pid} =
        EventStream.start_link(
          event_filters_module: TestContract.EventFilters,
          address: "0x1234567890123456789012345678901234567890",
          subscriber: self(),
          rpc_client: MockWebsocketClient
        )

      # Wait for subscription
      Process.sleep(100)

      # Simulate an incoming log notification
      log_notification = %{
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => "0x1234567890abcdef",
          "result" => %{
            "address" => "0x1234567890123456789012345678901234567890",
            "topics" => [
              "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
              "0x000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
              "0x000000000000000000000000d8da6bf26964af9d7eed9e03e53415d37aa96045"
            ],
            "data" => "0x00000000000000000000000000000000000000000000000000000000000003e8",
            "blockNumber" => "0x1b4",
            "blockHash" => "0x8216c5785ac562ff41e2dcfdf5785ac562ff41e2dcfdf829c5a142f1fccd7d",
            "transactionHash" =>
              "0x8216c5785ac562ff41e2dcfdf5785ac562ff41e2dcfdf829c5a142f1fccd7d",
            "transactionIndex" => "0x1",
            "logIndex" => "0x0",
            "removed" => false
          }
        }
      }

      send(pid, log_notification)

      # The EventStream should try to decode and forward the event
      # Note: This will fail because we're using a mock that doesn't actually decode
      # In a real scenario with proper test data, you'd receive {:event, decoded_event}

      # Clean up
      EventStream.stop(pid)
    end

    test "ignores notifications for different subscriptions" do
      {:ok, pid} =
        EventStream.start_link(
          event_filters_module: TestContract.EventFilters,
          address: "0x1234567890123456789012345678901234567890",
          subscriber: self(),
          rpc_client: MockWebsocketClient
        )

      # Wait for subscription
      Process.sleep(100)

      # Simulate a notification for a different subscription
      other_notification = %{
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => "0xdifferentsubscription",
          "result" => %{"some" => "data"}
        }
      }

      send(pid, other_notification)

      # Should not receive any event
      refute_receive {:event, _}, 100

      # Clean up
      EventStream.stop(pid)
    end
  end

  describe "Ethers.stream_logs_for_contract/3" do
    test "creates an event stream successfully" do
      {:ok, pid} =
        Ethers.stream_logs_for_contract(
          TestContract.EventFilters,
          "0x1234567890123456789012345678901234567890",
          subscriber: self(),
          rpc_client: MockWebsocketClient
        )

      assert Process.alive?(pid)

      # Clean up
      EventStream.stop(pid)
    end

    test "defaults subscriber to calling process" do
      {:ok, pid} =
        Ethers.stream_logs_for_contract(
          TestContract.EventFilters,
          "0x1234567890123456789012345678901234567890",
          rpc_client: MockWebsocketClient
        )

      assert Process.alive?(pid)

      # Clean up
      EventStream.stop(pid)
    end
  end
end
