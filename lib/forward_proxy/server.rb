require 'forward_proxy/thread_pool'
require 'socket'
require 'webrick'
require 'net/http'

module ForwardProxy
  class HTTPMethodNotImplemented < StandardError; end
  class HTTPParseError < StandardError; end

  class Server
    attr_reader :bind_address, :bind_port

    def initialize(bind_address: "127.0.0.1", bind_port: 9292, threads: 32)
      @thread_pool = ThreadPool.new(threads)
      @bind_address = bind_address
      @bind_port = bind_port
    end

    def start
      thread_pool.start

      @server = TCPServer.new(bind_address, bind_port)

      log("Listening #{bind_address}:#{bind_port}")

      loop do
        # The following comments are from "man 2 accept"
        #
        # The argument socket is a socket that has been created with socket(2), bound to an address with bind(2), and is listening for connections after a listen(2).  accept() extracts the
        # first connection request on the queue of pending connections, creates a new socket with the same properties of socket, and allocates a new file descriptor for the socket.  If no
        # pending connections are present on the queue, and the socket is not marked as non-blocking, accept() blocks the caller until a connection is present.  If the socket is marked
        # non-blocking and no pending connections are present on the queue, accept() returns an error as described below.  The accepted socket may not be used to accept more connections.
        # The original socket socket, remains open.
        thread_pool.schedule(server.accept) do |client_conn|
          begin
            req = parse_req(client_conn)

            log(req.request_line)

            case req.request_method
            when METHOD_CONNECT then handle_tunnel(client_conn, req)
            when METHOD_GET, METHOD_POST then handle(client_conn, req)
            else
              raise HTTPMethodNotImplemented
            end
          rescue => e
            client_conn.puts <<~eos.chomp
              HTTP/1.1 502
              Server: ForwardProxy
            eos

            puts e.message
            puts e.backtrace.map { |line| "  #{line}" }
          ensure
            client_conn.close
          end
        end
      end
    rescue Interrupt
      log("Exiting...")
    rescue IOError, Errno::EBADF => e
      log(e.message, "ERROR")
    end

    def shutdown
      log("Closing client connections...")
      thread_pool.shutdown

      log("Stoping server...")
      server.close if server
    end

    private

    attr_reader :server, :thread_pool

    METHOD_CONNECT = "CONNECT"
    METHOD_GET = "GET"
    METHOD_POST = "POST"

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
      resp = Net::HTTP.start(req.host, req.port) do |http|
        http.request map_webrick_to_net_http_req(req)
      end

      # A proxy MUST send an appropriate Via header field, as described
      # below, in each message that it forwards.  An HTTP-to-HTTP gateway
      # MUST send an appropriate Via header field in each inbound request
      # message and MAY send a Via header field in forwarded response
      # messages.
      client_conn.puts <<~eos.chomp
        HTTP/1.1 #{resp.code}
        Via: #{["1.1 ForwardProxy", resp['Via']].compact.join(', ')}
        #{resp.each.map { |header, value| "#{header}: #{value}" }.join("\n")}

        #{resp.body}
      eos
    end

    def map_webrick_to_net_http_req(req)
      req_headers = Hash[req.header.map { |k, v| [k, v.first] }]

      klass = case req.request_method
              when METHOD_GET then Net::HTTP::Get
              when METHOD_POST then Net::HTTP::Post
              else
                raise HTTPMethodNotImplemented
              end

      klass.new(req.path, req_headers)
    end

    def transfer(dest_conn, src_conn)
      IO.copy_stream(src_conn, dest_conn)
    rescue => e
      log(e.message, "WARNING")
    end

    def parse_req(client_conn)
      WEBrick::HTTPRequest.new(WEBrick::Config::HTTP).tap do |req|
        req.parse(client_conn)
      end
    rescue => e
      throw HTTPParseError.new(e.message)
    end

    def log(str, level = 'INFO')
      puts "[#{Time.now}] #{level} #{str}"
    end
  end
end
