require "securerandom"
require "em-websocket"
require "http_parser"

module EventMachine::WebSocket
  class Client < Connection
    def post_init
      url = @options.fetch(:url)
      if url.scheme == "wss"
        @secure = true
        @tls_options[:sni_hostname] ||= url.host
      end
      super
      @version = 13
      @key = SecureRandom.base64(16)
      @parser = Http::Parser.new
      @parser.on_headers_complete = proc do
        headers = @parser.headers
        @parser = nil
        accept = Digest::SHA1.base64digest(@key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
        unless headers["Connection"]&.downcase == "upgrade" &&
            headers["Upgrade"]&.downcase == "websocket" &&
            headers["Sec-WebSocket-Accept"] == accept
          raise HandshakeError, "Invalid server handshake"
        end
        debug [:handshake_completed]
        @handler = Handler.klass_factory(@version).prepend(ClientFraming).new(self, @debug)
        trigger_on_open(_handshake = nil)
        :stop
      end
      send_handshake unless @secure
    end

    def ssl_handshake_completed
      send_handshake
    end

    private

    def dispatch(data)
      @parser << data
    rescue HTTP::Parser::Error => e
      debug [:error, e]
      trigger_on_error(e)
      abort :handshake_error
    end

    def send_handshake
      url = @options.fetch(:url)
      send_data(
        "GET /ws/rem/relay HTTP/1.1\r\n" \
        "Host: #{url.host}\r\n" \
        "Connection: Upgrade\r\n" \
        "Upgrade: websocket\r\n" \
        "Sec-WebSocket-Version: #{@version}\r\n" \
        "Sec-WebSocket-Key: #{@key}\r\n\r\n"
      )
    end
  end

  module ClientFraming
    module C
      FIN = 0x80
      MASKED = 0x80
      FRAME_TYPES = Framing07::FRAME_TYPES
    end
    private_constant :C

    def send_frame(frame_type, data)
      head = String.new(capacity: 14)
      head << (C::FIN | C::FRAME_TYPES[frame_type])
      len = data.bytesize
      case len
      when 0..125
        head << [len | C::MASKED].pack("C")
      when 126..65535
        head << [126 | C::MASKED, len].pack("Cn")
      else
        head << [127 | C::MASKED, len].pack("CQ>")
      end
      mask_size = 4
      mask = SecureRandom.bytes(mask_size)
      head << mask
      dmask = mask * 2
      dm = dmask.unpack1("Q")
      dms = dmask.bytesize
      q, r = len.divmod(dms)
      q.times do |i|
        b = i * dms
        data[b, dms] = [data[b, dms].unpack1("Q") ^ dm].pack("Q")
      end
      r.times do |i|
        b = q * dms + i
        data.setbyte(b, data.getbyte(b) ^ dmask[i].ord)
      end
      @connection.send_data(head)
      @connection.send_data(data)
    end
  end
end
