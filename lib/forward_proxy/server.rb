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

    def initialize(bind_address: "127.0.0.1", bind_port: 9292, threads: 128, timeout: 300, logger: default_logger)
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
              when METHOD_GET, METHOD_HEAD, METHOD_POST then handle(client_conn, req)
              else
                raise Errors::HTTPMethodNotImplemented, "unsupported http method #{req.request_method}"
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
      socket.close if socket
    end

    private

    attr_reader :socket, :thread_pool

    METHOD_CONNECT, METHOD_GET, METHOD_HEAD, METHOD_POST = "CONNECT", "GET", "HEAD", "POST"

    # The following comments are from the IETF document
    # "Hypertext Transfer Protocol -- HTTP/1.1: Basic Rules"
    # https://datatracker.ietf.org/doc/html/rfc2616#section-2.2

    # HTTP/1.1 defines the sequence CR LF as the end-of-line marker for all
    # protocol elements except the entity-body.
    HTTP_EOP = "\r\n"

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
        #{HTTP_EOP}
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
            #{HTTP_EOP}
          eos

          # The following comments are taken from:
          # https://docs.ruby-lang.org/en/2.0.0/Net/HTTP.html#class-Net::HTTP-label-Streaming+Response+Bodies

          # By default Net::HTTP reads an entire response into memory. If you are
          # handling large files or wish to implement a progress bar you can
          # instead stream the body directly to an IO.
          resp.read_body do |chunk|
            # The following comments are taken from:
            # https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Transfer-Encoding#directives

            # Data is sent in a series of chunks. The Content-Length header is omitted in this case and
            # at the beginning of each chunk you need to add the length of the current chunk in
            # hexadecimal format, followed by '\r\n' and then the chunk itself, followed by another
            # '\r\n'. The terminating chunk is a regular chunk, with the exception that its length
            # is zero. It is followed by the trailer, which consists of a (possibly empty) sequence of
            # header fields.
            client_conn << chunk.bytesize.to_s(16) + HTTP_EOP if resp['Transfer-Encoding'] == 'chunked'

            client_conn << chunk
          end
        end
      end
    end

    def handle_error(client_conn, err)
      status_code = case err
                    when Errors::ConnectionTimeoutError then 504
                    when Errors::HTTPMethodNotImplemented then 501
                    else
                      502
                    end

      client_conn.puts <<~eos.chomp
        HTTP/1.1 #{status_code}
        Via: #{HEADER_VIA}
        #{HTTP_EOP}
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
              when METHOD_HEAD then Net::HTTP::Head
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
