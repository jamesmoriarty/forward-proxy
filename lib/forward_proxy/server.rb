require 'socket'
require 'webrick'
require 'net/http'

module ForwardProxy
  class HTTPMethodNotImplemented < StandardError; end

  class Server
    attr_reader :bind_address, :bind_port

    def initialize(bind_address: "127.0.0.1", bind_port: 9292)
      @bind_address = bind_address
      @bind_port = bind_port
    end

    def start
      @server = TCPServer.new(bind_address, bind_port)

      log("Listening #{bind_address}:#{bind_port}")

      loop do
        client = @server.accept

        Thread.start(client) do |client_conn|
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
            puts e.message
            puts e.backtrace.map { |line| "  #{line}" }
          ensure
            client_conn.close
          end
        end
      end
    end

    def shutdown
      log("Exiting...")
      @server.close if @server
    end

    private

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

      client_conn.puts <<~eos.chomp
        HTTP/1.1 #{resp.code}
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
    end

    def log(str, level = 'INFO')
      puts "[#{Time.now}] #{level} #{str}"
    end
  end
end
