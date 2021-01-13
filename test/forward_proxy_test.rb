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
      assert_equal "1.1 ForwardProxy", resp['via']
      assert_equal "http://www.google.com/", resp['location']
      body = <<~eos
        <HTML><HEAD><meta http-equiv="content-type" content="text/html;charset=utf-8">
        <TITLE>301 Moved</TITLE></HEAD><BODY>
        <H1>301 Moved</H1>
        The document has moved
        <A HREF="http://www.google.com/">here</A>.\r
        </BODY></HTML>\r
      eos
      assert_equal body, resp.body
    end
  end

  def test_handle_tunnel
    proxy(URI('https://google.com')) do |resp|
      assert_equal "301", resp.code
      assert_equal "https://www.google.com/", resp['location']
      body = <<~eos
        <HTML><HEAD><meta http-equiv="content-type" content="text/html;charset=utf-8">
        <TITLE>301 Moved</TITLE></HEAD><BODY>
        <H1>301 Moved</H1>
        The document has moved
        <A HREF="https://www.google.com/">here</A>.\r
        </BODY></HTML>\r
      eos
      assert_equal body, resp.body
    end
  end
end
