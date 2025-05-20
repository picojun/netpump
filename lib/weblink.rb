require "eventmachine"
require "em-websocket"
require "socket"
require "uri"
require "relay"
require "static_files"

class Weblink
  def initialize(
    client: nil,
    server: nil,
    host: "0.0.0.0",
    port: "8080",
    connection_inactivity_timeout: 30.0,
    proxy_host_loc: "0.0.0.0",
    proxy_port_loc: 3128,
    proxy_host_rem: "127.0.0.1",
    proxy_port_rem: 55000,
    websocket_pool_batch_size: 1,
    websocket_pool_max_size: 20
  )
    @client = client || client == server
    @server = server
    @host = host
    @port = port
    @connection_inactivity_timeout = connection_inactivity_timeout
    @proxy_host_loc = proxy_host_loc
    @proxy_port_loc = proxy_port_loc
    @proxy_host_rem = proxy_host_rem
    @proxy_port_rem = proxy_port_rem
    @websocket_pool = EventMachine::Queue.new
    @websocket_pool_batch_size = websocket_pool_batch_size
    @websocket_pool_max_size = websocket_pool_max_size
  end

  def run
    EventMachine.epoll
    EventMachine.error_handler do |e|
      log "[!] unexpected errback", error: e
    end
    EventMachine.run do
      trap(:INT) { puts; stop_eventmachine "[-] shutting down weblink.", signal: "sigint" }
      trap(:TERM) { stop_eventmachine "[-] shutting down weblink.", signal: "sigterm" }

      log "[+] starting weblink.", client: @client, server: @server, epoll: EventMachine.epoll?

      start_proxy_rem if @server
      start_websocket_server
      print_open_url if @client
    end
  end

  private

  def start_websocket_server
    EventMachine::WebSocket.run(host: @host, port: @port) do |ws|
      raise "websocket inactivity timeout" unless ws.comm_inactivity_timeout.zero?
      # Static server is only needed in client mode, but we need this to deploy
      # the server to Render because it sends HEAD / requests to check if the
      # app is up.
      ws.singleton_class.include(StaticFiles)
      ws.onerror do |e|
        log "[!] websocket error.", error: e
      end
      ws.onopen do |handshake|
        xff = handshake.headers_downcased["x-forwarded-for"]&.split(",", 2)&.first
        remote_ip = xff || ws.remote_ip
        ctx = {ip: remote_ip, sig: ws.signature}
        path = handshake.path
        if @client && path == "/ws/loc/control"
          log "[+] device is connected.", side: "loc", **ctx
          start_proxy_loc(ws, remote_ip)
        elsif @client && path == "/ws/loc/relay"
          log "[+] websocket is open.", side: "loc", **ctx
          @websocket_pool.push(ws)
        elsif @server && path == "/ws/rem/relay"
          log "[+] websocket is open.", side: "rem", **ctx
          bind_to_proxy(ws, remote_ip)
        else
          log "[!] unexpected request.", path: handshake.path
        end
      end
    end
  rescue RuntimeError => e
    stop_eventmachine "[!] websocket server error.", error: e
  else
    log "[+] websocket server is ready.", host: @host, port: @port
  end

  def start_proxy_loc(control_ws, remote_ip)
    bind_websocket = lambda do |relay|
      # Dogpile effect if batch size > 1.
      if @websocket_pool.empty?
        control_ws.send_text(@websocket_pool_batch_size.to_s)
        log "[~] websocket is requested.", side: "loc", cnt: @websocket_pool_batch_size, waitcnt: @websocket_pool.num_waiting
      end
      @websocket_pool.pop do |ws|
        if ws.state == :connected
          relay.set_comm_inactivity_timeout @connection_inactivity_timeout
          relay.bind(ws, remote_ip).callback do
            if @websocket_pool.size < @websocket_pool_max_size
              @websocket_pool.push(ws)
            else
              ws.close(1000, "purge")
            end
          end
        else
          log "[!] websocket is dead, retrying.", side: "loc", state: ws.state
          EventMachine.next_tick { bind_websocket.(relay) }
        end
      end
    end
    begin
      sig = EventMachine.start_server(@proxy_host_loc, @proxy_port_loc, Relay, "loc", method(:log), &bind_websocket)
    rescue RuntimeError => e
      stop_eventmachine "[!] local proxy server error.", error: e
    else
      control_ws.onclose do
        EventMachine.stop_server(sig)
        log "[-] device is disconnected.", side: "loc"
        log "[-] local proxy is stopped.", side: "loc"
      end
      log "[+] local proxy is ready.", side: "loc", type: "https", host: @proxy_host_loc, port: @proxy_port_loc
    end
  end

  def print_open_url
    ip = Socket.getifaddrs.find { |ifa| ifa.addr&.ipv4_private? } or abort(
      "[!] could not find an interface to listen on; " \
      "make sure that you are connected to your device."
    )
    open_url = URI::HTTP.build(host: ip.addr.ip_address, port: @port)
    log "[~] waiting for device to connect.", side: "loc", url: open_url
  end

  def start_proxy_rem
    require "em/protocols/connect"
  rescue LoadError
    abort "[!] install proxxy v2 to run weblink server."
  else
    begin
      EventMachine.start_server(@proxy_host_rem, @proxy_port_rem, EventMachine::Protocols::CONNECT, quiet: true) do |c|
        raise unless c.comm_inactivity_timeout.zero?
      end
    rescue RuntimeError => e
      stop_eventmachine "[!] remote proxy server error.", side: "rem", error: e
    else
      log "[+] remote proxy is ready.", side: "rem", type: "https", host: @proxy_host_rem, port: @proxy_port_rem
    end
  end

  def bind_to_proxy(ws, remote_ip)
    EventMachine.connect(@proxy_host_rem, @proxy_port_rem, Relay, "rem", method(:log)) do |relay|
      raise unless relay.comm_inactivity_timeout.zero?
      relay.bind(ws, remote_ip).callback { bind_to_proxy(ws, remote_ip) }
    end
  rescue RuntimeError => e
    log "[!] proxy connection error.", error: e
    ws.close(4000, "proxy connection error")
  end

  def stop_eventmachine(msg, **ctx)
    log msg, **ctx, fds: EventMachine.connection_count
    EventMachine.stop
  rescue RuntimeError => e
    log "[!] event machine error.", error: e.cause
  end

  def log(msg, **context)
    line = "%-35s" % msg
    context.each do |k, v|
      case v
      when Exception
        line << " #{k}=#{v.message.inspect}"
        line << " backtrace=#{v.backtrace}" if v.backtrace
      when true
        line << " #{k}"
      when false, nil, ""
        # skip
      else
        line << " #{k}=#{v}"
      end
    end
    $>.puts(line)
  end
end
