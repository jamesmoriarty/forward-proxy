require "test_helper"

class ForwardProxyTest < Minitest::Test
  def test_handle
    request(URI('http://google.com')) do |resp|
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

  def test_handle_with_unsupported_method
    uri = URI('http://google.com')

    request(uri, Net::HTTP::Trace.new(uri)) do |resp|
      assert_equal "502", resp.code
      assert_equal "ForwardProxy", resp['server']
    end
  end

  def test_handle_tunnel
    request(URI('https://google.com')) do |resp|
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
