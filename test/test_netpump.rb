require "minitest/autorun"
require "open-uri"
require "net/http"
require "uri"
require "netpump"

class TestNetpump < Minitest::Test
  $log = StringIO.new

  CLIENT_DIRECT = {mode: "direct", host: "127.0.0.1", port: 8001, proxy_host: "127.0.0.1", proxy_port: 3001, server_url: "ws://127.0.0.1:8003", websocket_pool_size: 4}.freeze
  private_constant :CLIENT_DIRECT

  CLIENT_BROWSER = {mode: "browser", host: "127.0.01", port: 8002, proxy_host: "127.0.0.1", proxy_port: 3002, server_url: "ws://127.0.0.1:8003", websocket_pool_size: 4}.freeze
  private_constant :CLIENT_BROWSER

  SERVER = {host: "127.0.0.1", port: "8003"}.freeze
  private_constant :SERVER

  server_thread = Thread.new(Thread.current) do |main|
    EventMachine.run do
      server = Netpump::Server.new(**SERVER)
      server.start
      client_direct = Netpump::Client.new(**CLIENT_DIRECT)
      client_direct.start.callback do
        client_browser = Netpump::Client.new(**CLIENT_BROWSER)
        client_browser.start.callback { main.wakeup }
        profile = Dir.mktmpdir("netpump-")
        EventMachine.add_shutdown_hook { FileUtils.remove_dir(profile) }
        url = URI::HTTP.build(CLIENT_BROWSER.slice(:host, :port))
        ff = EventMachine.system("firefox --profile #{profile.shellescape} --headless #{url}") do
          main.raise "firefox failure" unless EventMachine.stopping?
        end
        EventMachine.add_shutdown_hook do
          Process.kill(:TERM, ff)
        rescue Errno::ESRCH
        end
      end
    end
  end
  Minitest.after_run do
    EventMachine.stop
    server_thread.join
  end
  Thread.stop

  def test_that_sequential_requests_reuse_websockets
    [CLIENT_DIRECT, CLIENT_BROWSER].each do |client|
      # It would be ideal to request /healthcheck on the netpump server, but
      # net/http does not support using connect proxy with ssl off.
      out = capture do
        3.times { make_test_request(client) }
      end
      # Sequential requests must reuse websockets.
      # Two websockets are open at a time:
      # one to the client and one to the server.
      open_count = out.scan("websocket is open").size
      assert_includes [0, 2], open_count
    end
  end

  def test_that_parallel_requests_open_websockets
    [CLIENT_DIRECT, CLIENT_BROWSER].each do |client|
      n = client[:websocket_pool_size] * 2
      make_test_request(client)
      out = capture do
        request_threads = n.times.map do
          Thread.new { make_test_request(client) }
        end
        request_threads.each(&:join)
        make_test_request(client)
      end
      # Parallel requests open websockets.
      # A pair of websockets is already open from previous requests.
      # Ideally, the count should be n * 2 - 2, but some requests get finished
      # before the rest is sent, resulting in websocket reuse.
      open_count = out.scan("websocket is open").size
      assert_predicate open_count, :even?
      assert_operator open_count, :>=, n, out
      purge_count = out.scan("websocket is closed").size
      assert_predicate purge_count, :even?
      assert_equal open_count + 2 - n, purge_count, out
    end
  end

  def test_that_it_locks_down_once_browser_is_connected
    url = URI::HTTP.build(CLIENT_BROWSER.slice(:host, :port))
    url.path = "/ws/loc/control"
    assert_equal "404", Net::HTTP.get(url)
  end

  def test_that_only_get_requests_are_allowed
    Net::HTTP.start(*CLIENT_BROWSER.values_at(:host, :port)) do |http|
      response = http.head "/"
      assert_equal "405", response.code
    end
  end

  def test_that_it_aborts_invalid_websocket_requests
    client_url = URI::HTTP.build(CLIENT_BROWSER.slice(:host, :port))
    client_url.path = "/ws/loc/relay"
    server_url = URI::HTTP.build(SERVER.slice(:host, :port))
    server_url.path = "/ws/rem/relay"
    [client_url, server_url].each do |url|
      out = capture do
        assert_raises(EOFError) { Net::HTTP.get(url) }
      end
      # The error gets raised twice, which might be a bug in em-websocket.
      assert_match(/websocket error/, out, url)
      assert_match(/Not an upgrade request/, out)
    end
  end

  def test_that_there_is_no_websocket_server_in_direct_client_mode
    assert_raises(Errno::ECONNREFUSED) do
      Socket.tcp(*CLIENT_DIRECT.values_at(:host, :port))
    end
  end

  def test_that_localhost_is_inaccessible
    Socket.tcp(CLIENT_DIRECT[:proxy_host], CLIENT_DIRECT[:proxy_port]) do |socket|
      socket.write("CONNECT 127.0.0.1:8003 HTTP/1.1\r\n\r\n")
      assert_empty(socket.read)
    end
  end

  def test_that_server_responds_to_healthchecks
    url = URI::HTTP.build(SERVER.slice(:host, :port))
    ["/", "/healthcheck"].each do |path|
      url.path = path
      assert_equal "OK", Net::HTTP.get(url)
    end
  end

  private

  def make_test_request(client)
    proxy = URI::HTTP.build(host: client[:proxy_host], port: client[:proxy_port])
    response = URI.open("https://netpump.org", proxy: proxy)
    assert_equal "200", response.status.first
  end

  def capture
    $log.truncate(0)
    yield
    $log.string
  end
end
