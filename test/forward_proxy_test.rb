require "test_helper"

class ForwardProxyTest < Minitest::Test
  def test_handle_get
    uri = URI('http://127.0.0.1:8000/test/index.txt')

    with_dest(bind_address: uri.host, bind_port: uri.port, path: Dir.pwd) do
      with_proxy(uri) do |http|
        resp = http.request Net::HTTP::Get.new(uri)

        assert_equal "200", resp.code
        assert_equal "HTTP/1.1 ForwardProxy", resp['via']
        assert_equal "hello world", resp.body
      end
    end
  end

  def test_handle_post
    uri = URI('http://127.0.0.1:8000/test/index.txt')

    with_dest(bind_address: uri.host, bind_port: uri.port, path: Dir.pwd) do
      with_proxy(uri) do |http|
        resp = http.request Net::HTTP::Post.new(uri)

        assert_equal "405", resp.code
        assert_equal "HTTP/1.1 ForwardProxy", resp['via']
        refute_nil resp.body
      end
    end
  end

  def test_handle_with_unsupported_method
    uri = URI('http://127.0.0.1:8000/test/index.txt')

    with_dest(bind_address: uri.host, bind_port: uri.port, path: Dir.pwd) do
      with_proxy(uri) do |http|
        resp = http.request Net::HTTP::Trace.new(uri)

        assert_equal "502", resp.code
        assert_equal "HTTP/1.1 ForwardProxy", resp['via']
      end
    end
  end

  def test_handle_tunnel
    uri = URI('https://127.0.0.1:8000/test/index.txt')

    with_dest(https: true, bind_address: uri.host, bind_port: uri.port, path: Dir.pwd) do
      with_proxy(uri) do |http|
        resp = http.request Net::HTTP::Get.new(uri)

        assert_equal "200", resp.code
        assert_equal "hello world", resp.body
      end
    end
  end
end
