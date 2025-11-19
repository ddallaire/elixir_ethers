defmodule Ethers.EventStream do
  @moduledoc """
  A GenServer that manages WebSocket subscriptions for Ethereum contract events
  and automatically decodes incoming logs.

  This module provides real-time streaming of contract events via WebSocket,
  automatically decoding them using the contract's EventFilters module.

  ## Features

  * Real-time event streaming via WebSocket
  * Automatic event decoding using contract ABI
  * Support for filtering by contract address
  * Handles WebSocket connection management
  * Forwards decoded events to subscriber process
  * Automatic keep-alive to prevent connection timeouts (30s interval)

  ## Usage

  The typical way to use this module is through `Ethers.stream_logs_for_contract/3`:

  ```elixir
  # Start streaming events from a contract
  {:ok, stream_pid} = Ethers.stream_logs_for_contract(
    MyContract.EventFilters,
    "0x1234...",
    subscriber: self()
  )

  # Receive decoded events in your process
  receive do
    {:event, %Ethers.Event{} = event} ->
      IO.inspect(event)
  end

  # Stop streaming
  Ethers.EventStream.stop(stream_pid)
  ```

  You can also start the stream directly:

  ```elixir
  {:ok, pid} = Ethers.EventStream.start_link(
    event_filters_module: MyContract.EventFilters,
    address: "0x1234...",
    subscriber: self()
  )
  ```

  ## Options

  * `:event_filters_module` - (required) The EventFilters module from your contract
  * `:address` - The contract address to filter events from (nil means all contracts)
  * `:subscriber` - (required) The process that will receive decoded events
  * `:rpc_client` - The WebSocket RPC client to use (defaults to Ethereumex.WebsocketClient)
  * `:topics` - Custom topics filter (defaults to all events from the EventFilters module)

  ## Receiving Events

  Decoded events are sent to the subscriber process as `{:event, %Ethers.Event{}}` messages.
  Events that cannot be decoded (e.g., from other contracts) are silently ignored.

  If there's an error with the subscription, the subscriber will receive
  `{:event_stream_error, reason}` and the EventStream will terminate.
  """

  use GenServer
  require Logger

  alias Ethers.Event
  alias Ethers.Utils

  @type option ::
          {:event_filters_module, module()}
          | {:address, Ethers.Types.t_address() | nil}
          | {:subscriber, pid()}
          | {:rpc_client, module()}
          | {:topics, [binary()] | nil}

  @type options :: [option()]

  # Keep-alive ping interval in milliseconds (default: 30 seconds)
  # Most providers close idle connections after 30-60 seconds
  @keepalive_interval 30_000

  defstruct [
    :event_filters_module,
    :address,
    :subscriber,
    :subscription_id,
    :rpc_client,
    :topics,
    :keepalive_timer
  ]

  @doc """
  Starts an EventStream GenServer that subscribes to contract events via WebSocket.

  ## Options

  * `:event_filters_module` - (required) The EventFilters module from your contract
  * `:address` - The contract address to filter events from (nil means all contracts)
  * `:subscriber` - (required) The process that will receive decoded events
  * `:rpc_client` - The WebSocket RPC client to use (defaults to Ethereumex.WebsocketClient)
  * `:topics` - Custom topics filter (defaults to all events from the EventFilters module)

  ## Examples

      {:ok, pid} = Ethers.EventStream.start_link(
        event_filters_module: MyContract.EventFilters,
        address: "0x1234...",
        subscriber: self()
      )
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stops the EventStream and unsubscribes from the WebSocket.

  ## Examples

      Ethers.EventStream.stop(stream_pid)
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  @doc """
  Returns the current subscription ID for this stream.

  Returns `nil` if not yet subscribed.

  ## Examples

      {:ok, subscription_id} = Ethers.EventStream.get_subscription_id(stream_pid)
  """
  @spec get_subscription_id(pid()) :: {:ok, String.t() | nil}
  def get_subscription_id(pid) do
    GenServer.call(pid, :get_subscription_id)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    event_filters_module = Keyword.fetch!(opts, :event_filters_module)
    subscriber = Keyword.fetch!(opts, :subscriber)
    address = Keyword.get(opts, :address)
    rpc_client = Keyword.get(opts, :rpc_client, Ethereumex.WebsocketClient)
    topics = Keyword.get(opts, :topics)

    state = %__MODULE__{
      event_filters_module: event_filters_module,
      address: address,
      subscriber: subscriber,
      subscription_id: nil,
      rpc_client: rpc_client,
      topics: topics,
      keepalive_timer: nil
    }

    # Subscribe asynchronously after init completes
    send(self(), :subscribe)

    {:ok, state}
  end

  @impl true
  def handle_info(:subscribe, state) do
    topics = state.topics || build_topics_from_event_filters(state.event_filters_module)

    filter = build_filter(state.address, topics)

    case state.rpc_client.subscribe(:logs, filter) do
      {:ok, subscription_id} ->
        Logger.debug("EventStream subscribed with ID: #{subscription_id}")

        # Start keep-alive timer to prevent connection timeout
        keepalive_timer = schedule_keepalive()

        {:noreply, %{state | subscription_id: subscription_id, keepalive_timer: keepalive_timer}}

      {:error, reason} ->
        Logger.error("EventStream subscription failed: #{inspect(reason)}")
        send(state.subscriber, {:event_stream_error, reason})
        {:stop, {:subscription_failed, reason}, state}
    end
  end

  @impl true
  def handle_info(:keepalive, state) do
    # Send a simple request to keep the WebSocket connection alive
    # We use eth_chainId as it's lightweight and always available
    case state.rpc_client.eth_chain_id() do
      {:ok, _chain_id} ->
        # Connection is alive, schedule next keepalive
        keepalive_timer = schedule_keepalive()
        {:noreply, %{state | keepalive_timer: keepalive_timer}}

      {:error, reason} ->
        Logger.warning("Keep-alive check failed: #{inspect(reason)}")
        # Connection might be dead, but let reconnection logic handle it
        keepalive_timer = schedule_keepalive()
        {:noreply, %{state | keepalive_timer: keepalive_timer}}
    end
  end

  @impl true
  def handle_info(
        %{
          "method" => "eth_subscription",
          "params" => %{
            "subscription" => subscription_id,
            "result" => log
          }
        },
        %{subscription_id: subscription_id} = state
      ) do
    # This is a log notification for our subscription
    case Event.find_and_decode(log, state.event_filters_module) do
      {:ok, decoded_event} ->
        send(state.subscriber, {:event, decoded_event})

      {:error, :not_found} ->
        # Event not found in our EventFilters module, ignore it
        # This can happen if the address filter includes multiple contracts
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        %{
          "method" => "eth_subscription",
          "params" => %{
            "subscription" => other_subscription_id
          }
        },
        state
      ) do
    # This is a notification for a different subscription, ignore it
    Logger.debug(
      "Received notification for different subscription: #{other_subscription_id}, expected: #{state.subscription_id}"
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("EventStream received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_subscription_id, _from, state) do
    {:reply, {:ok, state.subscription_id}, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Cancel keep-alive timer
    if state.keepalive_timer do
      Process.cancel_timer(state.keepalive_timer)
    end

    # Unsubscribe when the GenServer terminates
    if state.subscription_id do
      case state.rpc_client.unsubscribe(state.subscription_id) do
        {:ok, true} ->
          Logger.debug("EventStream unsubscribed: #{state.subscription_id}")

        {:error, reason} ->
          Logger.warning("Failed to unsubscribe EventStream: #{inspect(reason)}")
      end
    end

    :ok
  end

  # Private Functions

  defp build_topics_from_event_filters(event_filters_module) do
    event_filters_module.__events__()
    |> Enum.map(fn %ABI.FunctionSelector{method_id: method_id} ->
      if method_id, do: Utils.hex_encode(method_id), else: nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp build_filter(nil, topics) do
    %{topics: [topics]}
  end

  defp build_filter(address, topics) do
    %{
      address: address,
      topics: [topics]
    }
  end

  defp schedule_keepalive do
    Process.send_after(self(), :keepalive, @keepalive_interval)
  end
end
