require "test_helper"

class ForwardProxyTest < Minitest::Test
  def test_handle_get
    uri = URI('http://google.com')

    with_proxy(uri) do |http|
      resp = http.request Net::HTTP::Get.new(uri)

      assert_equal "301", resp.code
      assert_equal "HTTP/1.1 ForwardProxy", resp['via']
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

  def test_handle_post
    uri = URI('http://google.com')

    with_proxy(uri) do |http|
      resp = http.request Net::HTTP::Post.new(uri)

      assert_equal "405", resp.code
      assert_equal "HTTP/1.1 ForwardProxy", resp['via']
      refute_nil resp.body
    end
  end

  def test_handle_with_unsupported_method
    uri = URI('http://google.com')

    with_proxy(uri) do |http|
      resp = http.request Net::HTTP::Trace.new(uri)

      assert_equal "502", resp.code
      assert_equal "HTTP/1.1 ForwardProxy", resp['via']
    end
  end

  def test_handle_tunnel
    uri = URI('https://google.com')

    with_proxy(uri) do |http|
      resp = http.request Net::HTTP::Get.new(uri)

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
