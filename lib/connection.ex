defmodule Kadabra.Connection do
  @moduledoc """
    Worker for maintaining an open HTTP/2 connection.
  """
  use GenServer
  require Logger

  alias Kadabra.{Error, Http2, Stream}

  @data 0x0
  @headers 0x1
  @rst_stream 0x3
  @settings 0x4
  @push_promise 0x5
  @ping 0x6
  @goaway 0x7
  @window_update 0x8

  def start_link(uri, pid, opts \\ []) do
    GenServer.start_link(__MODULE__, {:ok, uri, pid, opts})
  end

  def init({:ok, uri, pid, opts}) do
    case do_connect(uri, opts) do
      {:ok, socket} ->
        state = initial_state(socket, uri, pid, opts)
        {:ok, state}
      {:error, error} ->
        Logger.error(inspect(error))
        {:error, error}
    end
  end

  defp initial_state(socket, uri, pid, opts) do
   encoder = :hpack.new_context
   decoder = :hpack.new_context
   %{
      buffer: "",
      client: pid,
      uri: uri,
      scheme: opts[:scheme] || :https,
      opts: opts,
      socket: socket,
      stream_id: 1,
      streams: %{},
      reconnect: opts[:reconnect] || :true,
      encoder_state: encoder,
      decoder_state: decoder
    }
  end

  def do_connect(uri, opts) do
    case opts[:scheme] do
      :http -> {:error, :not_implemented}
      :https -> do_connect_ssl(uri, opts)
      _ -> {:error, :bad_scheme}
    end
  end

  def do_connect_ssl(uri, opts) do
    :ssl.start()
    ssl_opts = ssl_options(opts[:ssl])
    case :ssl.connect(uri, opts[:port], ssl_opts) do
      {:ok, ssl} ->
        :ssl.send(ssl, Http2.connection_preface)
        :ssl.send(ssl, Http2.settings_frame)
        {:ok, ssl}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ssl_options(nil), do: ssl_options([])
  defp ssl_options(opts) do
    opts ++ [
      {:active, :once},
      {:packet, :raw},
      {:reuseaddr, false},
      {:alpn_advertised_protocols, [<<"h2">>]},
      :binary
    ]
  end

  def handle_call(:get_info, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_cast({:recv, :data, frame}, state) do
    state = do_recv_data(frame, state)
    {:noreply, state}
  end

  def handle_cast({:recv, :headers, frame}, state) do
    state = do_recv_headers(frame, state)
    {:noreply, state}
  end

  def handle_cast({:send, :headers, headers}, state) do
    new_state = do_send_headers(headers, nil, state)
    {:noreply, inc_stream_id(new_state)}
  end

  def handle_cast({:send, :headers, headers, payload}, state) do
    new_state = do_send_headers(headers, payload, state)
    {:noreply, inc_stream_id(new_state)}
  end

  def handle_cast({:send, :goaway}, state) do
    do_send_goaway(state)
    {:noreply, inc_stream_id(state)}
  end

  def handle_cast({:recv, :goaway, frame}, state) do
    do_recv_goaway(frame, state)
    {:noreply, state}
  end

  def handle_cast({:recv, :settings, frame}, state) do
    state = do_recv_settings(frame, state)
    {:noreply, state}
  end

  def handle_cast({:send, :ping}, %{socket: socket} = state) do
    ping = Http2.build_frame(0x6, 0x0, 0x0, <<0, 0, 0, 0, 0, 0, 0, 0>>)
    :ssl.send(socket, ping)
    {:noreply, state}
  end

  def handle_cast({:recv, :ping, _frame}, %{client: pid} = state) do
    send(pid, {:ping, self()})
    {:noreply, state}
  end

  def handle_cast({:recv, :rst_stream, frame}, state) do
    {:noreply, do_recv_rst_stream(frame, state)}
  end

  def handle_cast({:recv, :window_update, %{stream_id: _stream_id,
                                            payload: payload}}, state) do

    <<_r::1, _window_size_inc::31>> = payload
    {:noreply, state}
  end

  def handle_cast(msg, state) do
    IO.inspect msg
    {:noreply, state}
  end

  defp inc_stream_id(%{stream_id: stream_id} = state) do
    %{state | stream_id: stream_id + 2}
  end

  defp do_recv_data(%{stream_id: stream_id} = frame, %{client: pid} = state) do
    stream = get_stream(stream_id, state)
    body = stream.body || ""
    stream = %Stream{stream | body: body <> frame[:payload]}

    if frame[:flags] == 0x1, do: send pid, {:end_stream, stream}

    put_stream(stream_id, state, stream)
  end

  defp do_recv_headers(%{stream_id: stream_id, flags: flags, payload: payload},
                       %{client: pid, decoder_state: dec} = state) do

    stream = get_stream(stream_id, state)
    {:ok, {headers, new_dec}} = :hpack.decode(payload, dec)
    stream = %Stream{ stream | headers: headers }

    state = %{state | decoder_state: new_dec}

    if flags == 0x5, do: send pid, {:end_stream, stream}

    put_stream(stream_id, state, stream)
  end

  defp do_send_headers(headers, payload, %{socket: socket,
                                           stream_id: stream_id,
                                           uri: uri,
                                           socket: socket,
                                           encoder_state: encoder,
                                           decoder_state: decoder} = state) do

    {:ok, pid} =
      %Stream{
        id: stream_id,
        uri: uri,
        connection: self(),
        socket: socket,
        encoder: encoder,
        decoder: decoder
      }
      |> Stream.start_link

    Registry.register(Registry.Kadabra, {uri, stream_id}, pid)

    :gen_statem.cast(pid, {:send_headers, headers, payload})

    state
  end

  defp do_send_goaway(%{socket: socket, stream_id: stream_id}) do
    h = Http2.goaway_frame(stream_id, Error.code("NO_ERROR"))
    :ssl.send(socket, h)
  end

  defp do_recv_goaway(frame, %{client: pid} = state) do
    <<_r::1, last_stream_id::31, code::32, rest::binary>> = frame[:payload]
    log_goaway(code, last_stream_id, rest)

    send pid, {:closed, self()}
    {:noreply, %{state | streams: %{}}}
  end

  def log_goaway(code, id, bin) do
    error = Error.string(code)
    Logger.error "Got GOAWAY, #{error}, Last Stream: #{id}, Rest: #{bin}"
  end

  defp do_recv_settings(frame, %{socket: socket,
                                 client: pid,
                                 decoder_state: decoder}  = state) do
    case frame[:flags] do
      0x1 -> # SETTINGS ACK
        send pid, {:ok, self()}
        state
      _ ->
        settings_ack = Http2.build_frame(@settings, 0x1, 0x0, <<>>)
        settings = parse_settings(frame[:payload])
        table_size = fetch_setting(settings, "SETTINGS_MAX_HEADER_LIST_SIZE")
        new_decoder = :hpack.new_max_table_size(table_size, decoder)

        :ssl.send(socket, settings_ack)
        send pid, {:ok, self()}
        %{state | decoder_state: new_decoder}
    end
  end

  def fetch_setting(settings, settings_key) do
    case Enum.find(settings, fn({key, _val}) -> key == settings_key end) do
      {^settings_key, value} -> value
      nil -> nil
    end
  end

  defp do_recv_rst_stream(frame, %{client: pid} = state) do
    code = :binary.decode_unsigned(frame[:payload])
    _error = Error.string(code)
    send pid, {:end_stream, get_stream(frame[:stream_id], state)}
  end

  defp put_stream(id, state, stream) do
    id = Integer.to_string(id)
    put_in(state, [:streams, id], stream)
  end

  defp get_stream(id, state) do
    id_string = Integer.to_string(id)
    state[:streams][id_string] || %Kadabra.Stream{id: id}
  end

  def handle_info({:finished, response}, %{client: pid} = state) do
    send(pid, {:end_stream, response})
    {:noreply, state}
  end

  def handle_info({:push_promise, stream}, %{client: pid} = state) do
    send(pid, {:push_promise, stream})
    {:noreply, state}
  end

  def handle_info({:tcp, _socket, _bin}, state) do
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    maybe_reconnect(state)
  end

  def handle_info({:ssl, _socket, bin}, state) do
    do_recv_ssl(bin, state)
  end

  def handle_info({:ssl_closed, _socket}, state) do
   maybe_reconnect(state)
  end

  defp do_recv_ssl(bin, %{socket: socket} = state) do
    bin = state[:buffer] <> bin
    case parse_ssl(socket, bin, state) do
      {:error, bin} ->
        :ssl.setopts(socket, [{:active, :once}])
        {:noreply, %{state | buffer: bin}}
    end
  end

  def parse_ssl(socket, bin, state) do
    case Http2.parse_frame(bin) do
      {:ok, frame, rest} ->
        handle_response(frame, state)
        parse_ssl(socket, rest, state)
      {:error, bin} ->
        {:error, bin}
    end
  end

  def handle_response(frame, _state) when is_binary(frame) do
    Logger.info "Got binary: #{inspect(frame)}"
  end
  def handle_response(frame, state) do
    pid =
      case Registry.lookup(Registry.Kadabra, {state.uri, frame.stream_id}) do
        [{_self, pid}] -> pid
        [] -> self()
      end

    case frame[:frame_type] do
      @data ->
        :gen_statem.cast(pid, {:recv_data, frame})
      @headers ->
        :gen_statem.cast(pid, {:recv_headers, frame})
      @rst_stream ->
        :gen_statem.cast(pid, {:recv_rst_stream, frame})
      @settings ->
        GenServer.cast(self(), {:recv, :settings, frame})
      @push_promise ->
        {:ok, pid} =
          %Stream{
            id: frame.stream_id,
            uri: state.uri,
            connection: self(),
            socket: state.socket,
            encoder: state.encoder_state,
            decoder: state.decoder_state
          }
          |> Stream.start_link

        Registry.register(Registry.Kadabra, {state.uri, frame.stream_id}, pid)
        GenServer.cast(pid, {:recv_push_promise, frame})
      @ping ->
        GenServer.cast(self(), {:recv, :ping, frame})
      @goaway ->
        GenServer.cast(self(), {:recv, :goaway, frame})
      @window_update ->
        GenServer.cast(self(), {:recv, :window_update, frame})
      _ ->
        Logger.debug("Unknown frame: #{inspect(frame)}")
    end
  end

  def settings_param(identifier) do
    case identifier do
      0x1 -> "SETTINGS_HEADER_TABLE_SIZE"
      0x2 -> "SETTINGS_ENABLE_PUSH"
      0x3 -> "SETTINGS_MAX_CONCURRENT_STREAMS"
      0x4 -> "SETTINGS_INITIAL_WINDOW_SIZE"
      0x5 -> "SETTINGS_MAX_FRAME_SIZE"
      0x6 -> "SETTINGS_MAX_HEADER_LIST_SIZE"
      error -> "Unknown #{error}"
    end
  end

  def parse_settings(<<>>), do: []
  def parse_settings(bin) do
    <<identifier::16, value::32, rest::bitstring>> = bin
    [{settings_param(identifier), value}] ++ parse_settings(rest)
  end

  def maybe_reconnect(%{reconnect: false, client: pid} = state) do
    Logger.debug "Socket closed, not reopening, informing client"
    send(pid, {:closed, self()})
    {:stop, :normal, state}
  end

  def maybe_reconnect(%{reconnect: true, uri: uri, opts: opts, client: pid} = state) do
    case do_connect(uri, opts) do
      {:ok, socket} ->
        Logger.debug "Socket closed, reopened automatically"
        state |> inspect |> Logger.info
        {:noreply, reset_state(state, socket)}
      {:error, error} ->
        Logger.error "Socket closed, reopening failed with #{error}"
        state |> inspect |> Logger.info
        send(pid, :closed)
         {:stop, :normal, state}
    end
  end

  defp reset_state(state, socket) do
    encoder = :hpack.new_context
    decoder = :hpack.new_context
    %{state | encoder_state: encoder,
              decoder_state: decoder,
              socket: socket,
              streams: %{}}
  end
end
