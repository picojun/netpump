module EventMachine::WebSocket::Server
  def self.start(host, port, &block)
    EventMachine::WebSocket.run(host: host, port: port, block: block) do |ws|
      ws.onerror do |e|
        if EventMachine::WebSocket::WebSocketError === e
          log "[!] websocket error.", error: e
        else
          fail e
        end
      end
      # WebSockets must not be closed because they are reused.
      fail "inactivity timeout" unless ws.comm_inactivity_timeout.zero?

      def ws.receive_data(data)
        # The data can be nil on error.
        return unless data
        # Technically, we need to buffer the data until the first CRLF.
        method, path, _httpv = data.split(" ", 3)
        path, _qs = path.split("?", 2)
        send_error = lambda do |status|
          send_data("HTTP/1.1 #{status}\r\n\r\n#{status}")
          close_connection_after_writing
          log "[!] http client error.", method: method, path: path, status: status
        end
        if method != "GET"
          send_error.call(405)
        else
          @options[:block].call(path, self) || send_error.call(404)
        end
        singleton_class.remove_method(__method__)
        singleton_class.remove_method(:serve_file)
        super if defined? @onopen
      end

      def ws.serve_file(path)
        send_data("HTTP/1.1 200 OK\r\n\r\n")
        # win: send/stream_file_data do not work on windows
        send_data(path.read)
        close_connection_after_writing
      end
    end
  end
end
