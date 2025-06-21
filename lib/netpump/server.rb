require "em-websocket"
require "eventmachine-proxy"
require "eventmachine/websocket/server"
require "socket"
require "netpump/relay"

module Netpump
  class Server
    def initialize(host: "0.0.0.0", port: 10000, proxy_host: "127.0.0.1", proxy_port: 0)
      @host = host
      @port = port
      @proxy_host = proxy_host
      @proxy_port = proxy_port
      @log = lambda { |msg, **ctx| log(msg, s: true, **ctx) }
    end

    def start
      @log.call "[+] netpump server is starting.", host: @host, port: @port
      start_websocket_server
      proxy = EventMachine.start_server(
        @proxy_host, @proxy_port, EventMachine::Protocols::CONNECT
      ) do |c|
        fail "inactivity timeout" unless c.comm_inactivity_timeout.zero?
      end
      @proxy_port, @proxy_host = Socket.unpack_sockaddr_in(EventMachine.get_sockname(proxy))
    end

    private

    def start_websocket_server
      EventMachine::WebSocket::Server.start(@host, @port) do |path, ws|
        case path
        when "/", "/healthcheck"
          @log.call "[~] http request.", method: "GET", path: path, ip: ws.remote_ip
          ws.send_healthcheck_response
        when "/ws/rem/relay"
          ws.onopen do |handshake|
            xff = handshake.headers_downcased["x-forwarded-for"]&.split(",", 2)&.first
            ip = xff || ws.remote_ip
            @log.call "[+] websocket is open.", ip: ip, sig: ws.signature
            bind(ws, ip)
          end
        else
          return false
        end
        true
      end
    end

    def bind(ws, ip)
      EventMachine.connect(@proxy_host, @proxy_port, Relay, "s") do |relay|
        fail "inactivity timeout" unless relay.comm_inactivity_timeout.zero?
        relay.bind(ws, ip).callback { bind(ws, ip) }
      end
    rescue RuntimeError => e
      @log.call "[!] proxy connection error.", error: e
      ws.close(4000, "proxy connection error")
    end
  end
end
