require 'openssl'
require 'webrick'
require 'webrick/https'
require 'simplecov'
SimpleCov.start

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "forward_proxy"

require "minitest/reporters"
Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

require "minitest/autorun"

def root_key
  @root_key ||= begin
    OpenSSL::PKey::RSA.new 2048 # the CA's public/private key
  end
end

def root_ca
  @root_ca ||= begin
    OpenSSL::X509::Certificate.new.tap do |root_ca|
      root_ca.version = 2 # cf. RFC 5280 - to make it a "v3" certificate
      root_ca.serial = 1
      root_ca.subject = OpenSSL::X509::Name.parse "/DC=org/DC=ruby-lang/CN=Ruby CA"
      root_ca.issuer = root_ca.subject # root CA's are "self-signed"
      root_ca.public_key = root_key.public_key
      root_ca.not_before = Time.now
      root_ca.not_after = root_ca.not_before + 2 * 365 * 24 * 60 * 60 # 2 years validity
      ef = OpenSSL::X509::ExtensionFactory.new
      ef.subject_certificate = root_ca
      ef.issuer_certificate = root_ca
      root_ca.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
      root_ca.add_extension(ef.create_extension("keyUsage", "keyCertSign, cRLSign", true))
      root_ca.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
      root_ca.add_extension(ef.create_extension("authorityKeyIdentifier", "keyid:always", false))
      root_ca.sign(root_key, OpenSSL::Digest::SHA256.new)
    end
  end
end

def key
  @key ||= begin
    OpenSSL::PKey::RSA.new 2048
  end
end

def cert
  @cert ||= begin
    OpenSSL::X509::Certificate.new.tap do |cert|
      cert.version = 2
      cert.serial = 2
      cert.subject = OpenSSL::X509::Name.parse "/DC=org/DC=ruby-lang/CN=Ruby certificate"
      cert.issuer = root_ca.subject # root CA is the issuer
      cert.public_key = key.public_key
      cert.not_before = Time.now
      cert.not_after = cert.not_before + 1 * 365 * 24 * 60 * 60 # 1 years validity
      ef = OpenSSL::X509::ExtensionFactory.new
      ef.subject_certificate = cert
      ef.issuer_certificate = root_ca
      cert.add_extension(ef.create_extension("keyUsage", "digitalSignature", true))
      cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
      cert.sign(root_key, OpenSSL::Digest::SHA256.new)
    end
  end
end

def with_dest(https: false)
  server = case https
           when true
             WEBrick::HTTPServer.new(
               Port: 8000,
               DocumentRoot: Dir.pwd,
               SSLEnable: true,
               SSLVerifyClient: OpenSSL::SSL::VERIFY_NONE,
               SSLCertificate: cert,
               SSLPrivateKey: key,
               SSLCertName: [["CN", WEBrick::Utils::getservername]]
             )
           else
             WEBrick::HTTPServer.new(Port: 8000, DocumentRoot: Dir.pwd)
           end

  server_thread = Thread.new { server.start }

  sleep 0.050 # 50ms

  yield if block_given?

  server.shutdown

  server_thread.join
end

def with_proxy(uri, bind_address: "127.0.0.1", bind_port: 3000, threads: 32)
  proxy = ForwardProxy::Server.new(
    bind_address: bind_address,
    bind_port: bind_port
  )

  proxy_thread = Thread.new { proxy.start }

  sleep 0.050 # 50ms

  Net::HTTP.start(
    uri.hostname,
    uri.port,
    proxy.bind_address,
    proxy.bind_port,
    use_ssl: uri.scheme == 'https',
    verify_mode: OpenSSL::SSL::VERIFY_NONE
  ) do |http|
    yield http if block_given?
  end

  proxy.shutdown

  proxy_thread.join
end
