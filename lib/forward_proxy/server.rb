require 'socket'
require 'webrick'
require 'net/http'
require 'forward_proxy/errors/http_method_not_implemented'
require 'forward_proxy/errors/http_parse_error'
require 'forward_proxy/thread_pool'

module ForwardProxy
  class Server
    attr_reader :bind_address, :bind_port

    def initialize(bind_address: "127.0.0.1", bind_port: 9292, threads: 32)
      @thread_pool = ThreadPool.new(threads)
      @bind_address = bind_address
      @bind_port = bind_port
    end

    def start
      thread_pool.start

      @socket = TCPServer.new(bind_address, bind_port)

      log("Listening #{bind_address}:#{bind_port}")

      loop do
        thread_pool.schedule(socket.accept) do |client_conn|
          begin
            req = parse_req(client_conn)

            log(req.request_line)

            case req.request_method
            when METHOD_CONNECT then handle_tunnel(client_conn, req)
            when METHOD_GET, METHOD_POST then handle(client_conn, req)
            else
              raise Errors::HTTPMethodNotImplemented
            end
          rescue => err
            handle_error(err, client_conn)
          ensure
            client_conn.close
          end
        end
      end
    rescue Interrupt
      shutdown
    rescue IOError, Errno::EBADF => e
      log(e.message, "ERROR")
    end

    def shutdown
      if socket
        log("Shutting down")

        socket.close
      end
    end

    private

    attr_reader :socket, :thread_pool

    METHOD_CONNECT = "CONNECT"
    METHOD_GET = "GET"
    METHOD_POST = "POST"

    # The following comments are from the IETF document
    # "Hypertext Transfer Protocol (HTTP/1.1): Semantics and Content"
    # https://tools.ietf.org/html/rfc7231#section-4.3.6

    # A proxy MUST send an appropriate Via header field, as described
    # below, in each message that it forwards.  An HTTP-to-HTTP gateway
    # MUST send an appropriate Via header field in each inbound request
    # message and MAY send a Via header field in forwarded response
    # messages.
    HEADER_VIA = "HTTP/1.1 ForwardProxy"

    def handle_tunnel(client_conn, req)
      # The following comments are from the IETF document
      # "Hypertext Transfer Protocol (HTTP/1.1): Semantics and Content"
      # https://tools.ietf.org/html/rfc7231#section-4.3.6

      # A client sending a CONNECT request MUST send the authority form of
      # request-target (Section 5.3 of [RFC7230]); i.e., the request-target
      # consists of only the host name and port number of the tunnel
      # destination, separated by a colon.  For example,
      #
      #   CONNECT server.example.com:80 HTTP/1.1
      #   Host: server.example.com:80
      #
      host, port = *req['Host'].split(':')
      dest_conn = TCPSocket.new(host, port)

      # Any 2xx (Successful) response indicates that the sender (and all
      # inbound proxies) will switch to tunnel mode immediately after the
      # blank line that concludes the successful response's header section;
      # data received after that blank line is from the server identified by
      # the request-target.
      client_conn.write "HTTP/1.1 200 OK\n\n"

      # The CONNECT method requests that the recipient establish a tunnel to
      # the destination origin server identified by the request-target and,
      # if successful, thereafter restrict its behavior to blind forwarding
      # of packets, in both directions, until the tunnel is closed.
      [
        Thread.new { transfer(client_conn, dest_conn) },
        Thread.new { transfer(dest_conn, client_conn) }
      ].each(&:join)
    ensure
      dest_conn.close
    end

    def handle(client_conn, req)
      Net::HTTP.start(req.host, req.port) do |http|
        http.request(map_webrick_to_net_http_req(req)) do |resp|
          headers= resp.to_hash.merge(Via: [HEADER_VIA, resp['Via']].compact.join(', '))

          client_conn.puts <<~eos.chomp
            HTTP/1.1 #{resp.code}
            #{headers.map { |header, value| "#{header}: #{value}" }.join("\n")}\n\n
          eos

          # The following comments are taken from:
          # https://docs.ruby-lang.org/en/2.0.0/Net/HTTP.html#class-Net::HTTP-label-Streaming+Response+Bodies

          # By default Net::HTTP reads an entire response into memory. If you are
          # handling large files or wish to implement a progress bar you can
          # instead stream the body directly to an IO.
          resp.read_body do |chunk|
            client_conn << chunk
          end
        end
      end
    end

    def handle_error(err, client_conn)
      client_conn.puts <<~eos.chomp
        HTTP/1.1 502
        Via: #{HEADER_VIA}
      eos

      log(err.message, "ERROR")
      puts err.backtrace.map { |line| "  #{line}" }
    end

    def map_webrick_to_net_http_req(req)
      req_headers = Hash[req.header.map { |k, v| [k, v.first] }]

      klass = case req.request_method
              when METHOD_GET then Net::HTTP::Get
              when METHOD_POST then Net::HTTP::Post
              else
                raise Errors::HTTPMethodNotImplemented
              end

      klass.new(req.path, req_headers)
    end

    def transfer(src_conn, dest_conn)
      IO.copy_stream(src_conn, dest_conn)
    rescue => e
      log(e.message, "WARNING")
    end

    def parse_req(client_conn)
      WEBrick::HTTPRequest.new(WEBrick::Config::HTTP).tap do |req|
        req.parse(client_conn)
      end
    rescue => e
      throw Errors::HTTPParseError.new(e.message)
    end

    def log(str, level = 'INFO')
      puts "[#{Time.now}] #{level} #{str}"
    end
  end
end
