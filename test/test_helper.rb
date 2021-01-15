require 'simplecov'
SimpleCov.start

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "forward_proxy"

require "minitest/reporters"
Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

require "minitest/autorun"

def request(uri, req = Net::HTTP::Get.new(uri))
  proxy = ForwardProxy::Server.new(
    bind_address: "127.0.0.1",
    bind_port: 3000
  )

  proxy_thread = Thread.new { proxy.start }

  sleep 1

  Net::HTTP.start(
    uri.hostname,
    uri.port,
    proxy.bind_address,
    proxy.bind_port,
    use_ssl: uri.scheme == 'https'
  ) do |http|
    yield http.request req
  end

  proxy.shutdown

  proxy_thread.join
end
