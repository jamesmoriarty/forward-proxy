require "test_helper"

class ForwardProxyTest < Minitest::Test
  def test_handle_get
    with_dest(uri = URI('http://127.0.0.1:8000/test/index.txt')) do
      with_proxy(uri) do |http|
        resp = http.request Net::HTTP::Get.new(uri)

        assert_equal "200", resp.code
        assert_match /WEBrick\//, resp['server']
        assert_equal "HTTP/1.1 ForwardProxy", resp['via']
        assert_equal "hello world", resp.body
      end
    end
  end

  def test_handle_head
    with_dest(uri = URI('http://127.0.0.1:8000/test/index.txt')) do
      with_proxy(uri) do |http|
        resp = http.request Net::HTTP::Head.new(uri)

        assert_equal "200", resp.code
        assert_match /WEBrick\//, resp['server']
        assert_equal "HTTP/1.1 ForwardProxy", resp['via']
        assert_equal nil, resp.body
      end
    end
  end

  def test_handle_post
    with_dest(uri = URI('http://127.0.0.1:8000/test/index.txt')) do
      with_proxy(uri) do |http|
        resp = http.request Net::HTTP::Post.new(uri)

        assert_equal "405", resp.code
        assert_match /WEBrick\//, resp['server']
        assert_equal "HTTP/1.1 ForwardProxy", resp['via']
        assert_match /Method Not Allowed/, resp.body
      end
    end
  end

  def test_handle_with_unsupported_method
    with_dest(uri = URI('http://127.0.0.1:8000/test/index.txt')) do
      with_proxy(uri) do |http|
        resp = http.request Net::HTTP::Trace.new(uri)

        assert_equal "501", resp.code
        assert_equal "HTTP/1.1 ForwardProxy", resp['via']
        assert_equal "", resp.body
      end
    end
  end

  def test_handle_tunnel
    with_dest(uri = URI('https://127.0.0.1:8000/test/index.txt')) do
      with_proxy(uri) do |http|
        resp = http.request Net::HTTP::Get.new(uri)

        assert_equal "200", resp.code
        assert_match /WEBrick\//, resp['server']
        assert_equal "hello world", resp.body
      end
    end
  end

  def test_handle_error_with_timeout
    app = Proc.new do |req, res|
      rd, wr = IO.pipe
      res.body = rd
      sleep 1 # 1000ms
      wr.close
    end

    with_dest(uri = URI('http://127.0.0.1:8000/stream'), { '/stream' => app }) do
      with_proxy(uri, timeout: 1/20r) do |http| # 50ms
        resp = http.request Net::HTTP::Get.new(uri)

        assert_equal "504", resp.code
      end
    end
  end

  def test_stream_response_body
    called = 0
    content_body = "0123456789" * 1_000
    response_body = ""

    app = Proc.new do |req, res|
      res.status = 200
      res['Content-Type'] = 'text/plain'
      res.chunked = true
      res.body = content_body
      res['Content-Length'] = content_body.length
    end

    with_dest(uri = URI('http://127.0.0.1:8000/chunked'), { '/chunked' => app }) do
      with_proxy(uri) do |http|
        begin
          resp = http.request Net::HTTP::Get.new(uri) do |response|
            response.read_body do |chunk|
              response_body += chunk
              called += 1
            end
          end
        rescue EOFError # https://bugs.ruby-lang.org/issues/14972
          called += 1
        end

        assert 1 < called
        assert_match content_body, response_body
      end
    end
  end

  def test_logger
    with_dest(uri = URI('http://127.0.0.1:8000/test/index.txt')) do
      with_proxy(uri, logger: Logger.new(io = StringIO.new)) do |http|
        resp = http.request Net::HTTP::Get.new(uri)

        assert_equal "200", resp.code
        assert_match /GET.*\/test\/index.txt HTTP\/1.1/, io.string
      end
    end
  end
end
