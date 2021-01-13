require "test_helper"

class ForwardProxyTest < Minitest::Test
  def proxy(uri)
    server = ForwardProxy::Server.new(bind_address: "127.0.0.1", bind_port: 3000)
    Thread.new { server.start }
    sleep 1

    Net::HTTP.start(uri.hostname, uri.port, server.bind_address, server.bind_port, use_ssl: uri.scheme == 'https') do |http|
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
