require "test_helper"

ENV['https_proxy'] = "http://127.0.0.1:3000"

class ForwardProxyTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::ForwardProxy::VERSION
  end

  def proxy(uri)
    hostname = "127.0.0.1"
    port = 3000

    server = ForwardProxy::Server.new(hostname: hostname, port: port)

    Thread.new { server.start }

    sleep 1

    Net::HTTP.start(uri.hostname, uri.port, hostname, port, use_ssl: uri.scheme == 'https') do |http|
      yield http.request Net::HTTP::Get.new(uri)
    end

    server.shutdown
  end

  def test_handle
    proxy(URI('http://google.com')) do |resp|
      assert_equal "301", resp.code
    end
  end

  def test_handle_tunnel
    proxy(URI('https://google.com')) do |resp|
      assert_equal "301", resp.code
    end
  end
end
