$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "forward_proxy"

require "minitest/reporters"
Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

require "minitest/autorun"

