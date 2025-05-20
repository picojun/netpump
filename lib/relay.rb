class Relay < EventMachine::Connection
  def initialize(side, logproc)
    super
    pause
    @ws = nil
    @sig = nil
    @completion = nil
    @closed = false
    @unbind_sent = false
    @unbind_recv = false
    @remote_ip = nil
    @connection_inactivity_timeout = 0.0
    @log = lambda { |msg, **ctx| logproc[msg, side: side, ip: @remote_ip, sig: @sig, **ctx] }
  end

  def bind(ws, remote_ip)
    @ws = ws
    @sig = "#{ws.signature}.#{signature}"
    @completion = EventMachine::Completion.new
    @closed = false
    @unbind_sent = false
    @unbind_recv = false
    @remote_ip = remote_ip
    @connection_inactivity_timeout = comm_inactivity_timeout
    @log.call "[+] bind."
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
          close_connection
        end
      else
        @log.call "[!] unexpected text on websocket.", msg: msg
      end
    end
    @ws.onclose do
      close_connection
      @completion.fail
      close_info = @ws.instance_variable_get(:@handler).instance_variable_get(:@close_info) || {}
      code = close_info[:code]
      reason = close_info[:reason]
      if reason
        reason = reason.empty? ? nil : reason.inspect
      end
      @log.call "[-] websocket is closed.", code: code, reason: reason
    end
    resume
    @completion
  end

  def receive_data(data)
    @ws.send_binary(data)
  end

  def unbind(errno)
    if errno
      if errno == Errno::ETIMEDOUT && @connection_inactivity_timeout > 0
        reason = "inactivity"
      elsif errno.respond_to?(:exception)
        reason = errno.exception.message
        reason[0] = reason[0].downcase
      else
        # win: errno can be set to :unknown on windows
        reason = errno.to_s
      end
      reason = reason.inspect
    end
    @log.call "[-] unbind.", reason: reason
    @closed = true
    if @ws&.state == :connected
      @ws.send_text("unbind")
      @unbind_sent = true
      @completion&.succeed if @unbind_recv
    end
  end
end
