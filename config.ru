require 'rack'
require 'net/http'

# https_proxy=http://127.0.0.1:9292 curl -v https://google.com
def handle_tunnel(req)
  [501, { "Content-Type" => "text/html" }, ["Not Implemented"]]
end

# http_proxy=http://127.0.0.1:9292 curl -v http://google.com
def handle(req)
  resp = Net::HTTP.get_response(req.host, req.path)

  [resp.code, resp.header, [resp.body]]
end

proxy = proc do |env|
  req = Rack::Request.new(env)

  begin
    case req.request_method
    when "CONNECT"
      handle_tunnel(req)
    else
      handle(req)
    end
  rescue => e
    require 'pp'

    pp(e)

    pp(req)

    [502, { "Content-Type" => "text/html" }, ["Bad Gateway"]]
  end
end

run proxy
