require "em-websocket"
require "eventmachine"
require "eventmachine/websocket/client"
require "eventmachine/websocket/server"
require "pathname"
require "socket"
require "uri"
require "netpump/relay"

module Netpump
  class Client
    def initialize(
      mode: "direct",
      host: "0.0.0.0",
      port: "8080",
      proxy_host: "127.0.0.1",
      proxy_port: 3128,
      server_url: "wss://weblink-ouux.onrender.com",
      connection_inactivity_timeout: 30.0,
      websocket_pool_size: 20,
      websocket_pool_timeout: 60.0
    )
      @mode = mode
      @host = host if mode == "browser"
      @port = port if mode == "browser"
      @proxy_host = proxy_host
      @proxy_port = proxy_port
      @server_url = URI(server_url)
      @connection_inactivity_timeout = connection_inactivity_timeout
      @websocket_pool = EventMachine::Queue.new
      @websocket_pool_size = websocket_pool_size
      @websocket_pool_timeout = websocket_pool_timeout
      @control_ws = nil
      @log = lambda { |msg, **ctx| log(msg, c: true, **ctx) }
      @ready = EventMachine::Completion.new
    end

    def start
      @log.call "[+] netpump client is starting.", mode: @mode, host: @host, port: @port
      case @mode
      when "direct"
        start_proxy_server
        @ready.succeed
      when "browser"
        start_websocket_server
        print_open_url
      end
      @ready
    end

    private

    PUBLIC_DIR = Pathname(__dir__).parent.parent.join("public").freeze
    private_constant :PUBLIC_DIR

    def start_websocket_server
      EventMachine::WebSocket::Server.start(@host, @port) do |path, ws|
        case path
        when "/"
          ws.serve_file(PUBLIC_DIR.join("netpump.html"))
          @log.call "[~] http request.", method: "GET", path: path, ip: ws.remote_ip
        when "/favicon.svg"
          ws.serve_file(PUBLIC_DIR.join("favicon.svg"))
          @log.call "[~] http request.", method: "GET", path: path, ip: ws.remote_ip
        when "/ws/loc/control"
          next false if @control_ws
          ws.onopen do |_handshake|
            @log.call "[+] device is connected.", ip: ws.remote_ip
            @control_ws = ws
            @control_ws.send_text(@server_url.to_s)
            proxy = start_proxy_server
            @control_ws.onclose do
              @control_ws = nil
              @log.call "[-] device is disconnected.", sig: ws.signature
              EventMachine.stop_server(proxy)
              @log.call "[-] proxy server is stopped."
            end
            @ready.succeed
          end
        when "/ws/loc/relay"
          next false unless @control_ws.remote_ip == ws.remote_ip
          ws.onopen do |_handshake|
            @log.call "[+] websocket is open.", ip: ws.remote_ip, sig: ws.signature
            @websocket_pool << ws
          end
        else
          next false
        end
        true
      end
    end

    def print_open_url
      ip = Socket.getifaddrs.find { |ifa| ifa.addr&.ipv4_private? } or raise(
        "could not find an interface to listen on; " \
        "make sure that you are connected to your device."
      )
      open_url = URI::HTTP.build(host: ip.addr.ip_address, port: @port)
      @log.call "[~] waiting for device to connect.", url: open_url
    end

    def start_proxy_server
      proxy = EventMachine.start_server(@proxy_host, @proxy_port, Relay, "c") do |relay|
        bind(relay)
      end
      @log.call "[+] proxy server is ready.", type: "https", host: @proxy_host, port: @proxy_port
      proxy
    end

    def bind(relay)
      if @websocket_pool.empty?
        case @mode
        when "direct"
          host = @server_url.host
          port = @server_url.port
          begin
            EventMachine.connect(host, port, EventMachine::WebSocket::Client, url: @server_url) do |ws|
              ws.onopen do
                @log.call "[+] websocket is open.", ip: ws.remote_ip, sig: ws.signature
                @websocket_pool << ws
              end
            end
          rescue EventMachine::ConnectionError => e
            @log.call "[!] server connection error.", error: e
            return relay.close("server connection error")
          end
        when "browser"
          # Dogpile effect if batch size > 1.
          @control_ws.send_text(_batch_size = "1")
        end
        @log.call "[~] websocket is requested.", waitcnt: @websocket_pool.num_waiting
      end
      timeout = EventMachine::Timer.new(@websocket_pool_timeout) do
        relay.close("pool timeout")
        raise "race condition" unless EventMachine.reactor_thread?
        @websocket_pool.instance_variable_get(:@popq).shift || raise("popq")
      end
      @websocket_pool.pop do |ws|
        timeout.cancel
        if ws.state != :connected
          # When the browser tab is closed or reloaded, all local websockets
          # are closed, remaining dead in the pool until popped.
          @log.call "[~] websocket is dead, retrying.", state: ws.state, sig: ws.signature
          EventMachine.next_tick { bind(relay) }
        else
          relay.set_comm_inactivity_timeout(@connection_inactivity_timeout)
          relay.bind(ws, ws.remote_ip).callback do
            if @websocket_pool.size < @websocket_pool_size
              @websocket_pool << ws
            else
              ws.close(1000, "purge")
            end
          end
        end
      end
    end
  end
end
