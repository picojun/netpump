module Netpump
  class Relay < EventMachine::Connection
    def initialize(
      side,
      connection_inactivity_timeout: 0.0,
      backpressure_min_bytes: 2**23,
      backpressure_max_bytes: 2**24,
      backpressure_drain_seconds: 1.0
    )
      pause
      @ws = nil
      @completion = nil
      @closed = false
      @close_reason = nil
      @unbind_sent = false
      @unbind_recv = false
      @connection_inactivity_timeout = connection_inactivity_timeout
      @backpressure_min_bytes = backpressure_min_bytes
      @backpressure_max_bytes = backpressure_max_bytes
      @backpressure_drain_seconds = backpressure_drain_seconds
      @remote_ip = nil
      @sig = "-.#{signature}"
      @log = lambda do |msg, **ctx|
        log(msg, "#{side}": true, ip: @remote_ip, sig: @sig, **ctx)
      end
    end

    def bind(ws, remote_ip)
      @ws = ws
      @sig = "#{ws.signature}.#{signature}"
      @completion = EventMachine::Completion.new
      @unbind_sent = false
      @unbind_recv = false
      @remote_ip = remote_ip
      @connection_inactivity_timeout = comm_inactivity_timeout
      if @closed
        # If a connection is closed due to the pool timeout before being bound to
        # a websocket, it is not added to the wait queue in the websocket pool,
        # so this case should not happen under normal operation. However, it is
        # still possible is the connection is closed due to any other reason.
        @log.call "[!] bound closed before bind."
        @completion.succeed
        return @completion
      end
      @ws.onbinary do |data|
        if @closed
          @log.call "[~] data discard, bound closed.", connerror: error?, bytes: data.bytesize
        else
          send_data(data)
        end
      end
      @ws.onmessage do |msg|
        if msg == "unbind"
          @unbind_recv = true
          if @unbind_sent
            @completion.succeed
          else
            close("unbind")
          end
        else
          @log.call "[!] unexpected text on websocket.", msg: msg[0, 16].inspect
        end
      end
      @ws.onclose do |close_info|
        close("websocket closed") unless @closed
        @completion.fail
        @log.call "[-] websocket is closed.", **close_info.slice(:code, :reason)
      end
      resume
      @log.call "[+] bind."
      @completion
    end

    def receive_data(data)
      @ws.send_binary(data)
      check_backpressure
    end

    def close(reason)
      fail "double close" if @closed
      @close_reason = reason
      close_connection_after_writing
    end

    def unbind(errno)
      @closed = true
      if @ws&.state == :connected
        @ws.send_text("unbind")
        @unbind_sent = true
        @completion&.succeed if @unbind_recv
      end
      if errno.nil?
        reason = @close_reason
      elsif errno == Errno::ETIMEDOUT && @connection_inactivity_timeout > 0
        reason = "inactive"
      elsif errno.respond_to?(:exception)
        reason = errno.exception.message
        reason[0] = reason[0].downcase
      else
        # win: errno can be set to :unknown on windows
        reason = errno.to_s
      end
      @log.call "[-] unbind.", reason: reason
    end

    private

    def check_backpressure
      outbound_bytes = @ws.get_outbound_data_size
      if outbound_bytes >= @backpressure_max_bytes && !paused?
        pause
        @log.call "[~] paused.", outbytes: outbound_bytes
      end
      if outbound_bytes <= @backpressure_min_bytes && paused?
        resume
        @log.call "[~] resumed.", outbytes: outbound_bytes
      end
      if paused?
        EventMachine::Timer.new(@backpressure_drain_seconds) do
          check_backpressure
        end
      end
    end
  end
  private_constant :Relay
end
