require 'logger'
require 'socket'
require 'timeout'
require 'net/http'
require 'webrick'
require 'forward_proxy/errors/connection_timeout_error'
require 'forward_proxy/errors/http_method_not_implemented'
require 'forward_proxy/errors/http_parse_error'
require 'forward_proxy/thread_pool'

module ForwardProxy
  class Server
    attr_reader :bind_address, :bind_port, :logger, :timeout

    def initialize(bind_address: "127.0.0.1", bind_port: 9292, threads: 4, timeout: 300, logger: default_logger)
      @bind_address = bind_address
      @bind_port = bind_port
      @logger = logger
      @thread_pool = ThreadPool.new(threads)
      @timeout = timeout
    end

    def start
      thread_pool.start

      @socket = TCPServer.new(bind_address, bind_port)

      logger.info("Listening #{bind_address}:#{bind_port}")

      loop do
        thread_pool.schedule(socket.accept) do |client_conn|
          begin
            Timeout::timeout(timeout, Errors::ConnectionTimeoutError, "connection exceeded #{timeout} seconds") do
              req = parse_req(client_conn)

              logger.info(req.request_line.strip)

              case req.request_method
              when METHOD_CONNECT then handle_tunnel(client_conn, req)
              when METHOD_GET, METHOD_POST then handle(client_conn, req)
              else
                raise Errors::HTTPMethodNotImplemented
              end
            end
          rescue => e
            handle_error(client_conn, e)
          ensure
            client_conn.close
          end
        end
      end
    rescue Interrupt
      shutdown
    rescue IOError, Errno::EBADF => e
      logger.error(e.message)
    end

    def shutdown
      if socket
        logger.info("Shutting down")

        socket.close
      end
    end

    private

    attr_reader :socket, :thread_pool

    # The following comments are from the IETF document
    # "Hypertext Transfer Protocol -- HTTP/1.1: Basic Rules"
    # https://datatracker.ietf.org/doc/html/rfc2616#section-2.2

    METHOD_CONNECT = "CONNECT"
    METHOD_GET = "GET"
    METHOD_POST = "POST"

    # HTTP/1.1 defines the sequence CR LF as the end-of-line marker for all
    # protocol elements except the entity-body.
    HEADER_EOP = "\r\n"

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
      client_conn.write <<~eos.chomp
        HTTP/1.1 200 OK
        #{HEADER_EOP}
      eos

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
          # The following comments are from the IETF document
          # "Hypertext Transfer Protocol (HTTP/1.1): Semantics and Content"
          # https://tools.ietf.org/html/rfc7231#section-4.3.6

          # An intermediary MAY combine an ordered subsequence of Via header
          # field entries into a single such entry if the entries have identical
          # received-protocol values.  For example,
          #
          #   Via: 1.0 ricky, 1.1 ethel, 1.1 fred, 1.0 lucy
          #
          # could be collapsed to
          #
          #   Via: 1.0 ricky, 1.1 mertz, 1.0 lucy
          #
          # A sender SHOULD NOT combine multiple entries unless they are all
          # under the same organizational control and the hosts have already been
          # replaced by pseudonyms.  A sender MUST NOT combine entries that have
          # different received-protocol values.
          headers = resp.to_hash.merge(Via: [HEADER_VIA, resp['Via']].compact.join(', '))

          client_conn.puts <<~eos.chomp
            HTTP/1.1 #{resp.code}
            #{headers.map { |header, value| "#{header}: #{value}" }.join("\n")}
            #{HEADER_EOP}
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

    def handle_error(client_conn, err)
      status_code = case err
                    when Errors::ConnectionTimeoutError then 504
                    else
                      502
                    end

      client_conn.puts <<~eos.chomp
        HTTP/1.1 #{status_code}
        Via: #{HEADER_VIA}
        #{HEADER_EOP}
      eos

      logger.error(err.message)
      logger.debug(err.backtrace.join("\n"))
    end

    def default_logger
      Logger.new(STDOUT, level: :info)
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
      logger.warn(e.message)
    end

    def parse_req(client_conn)
      WEBrick::HTTPRequest.new(WEBrick::Config::HTTP).tap do |req|
        req.parse(client_conn)
      end
    rescue => e
      throw Errors::HTTPParseError.new(e.message)
    end
  end
end
