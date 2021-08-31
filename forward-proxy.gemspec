# frozen_string_literal: true

require_relative 'lib/forward_proxy/version'

Gem::Specification.new do |spec|
  spec.name          = 'forward-proxy'
  spec.version       = ForwardProxy::VERSION
  spec.authors       = ['James Moriarty']
  spec.email         = ['jamespaulmoriarty@gmail.com']

  spec.summary       = 'Forward proxy.'
  spec.description   = 'Minimal forward proxy using 150LOC and only standard libraries. Useful for development, testing, and learning.'
  spec.homepage      = 'https://github.com/jamesmoriarty/forward-proxy'
  spec.license       = 'MIT'
  spec.required_ruby_version = Gem::Requirement.new('>= 2.3.0')

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/jamesmoriarty/forward-proxy'
  spec.metadata['changelog_uri'] = 'https://github.com/jamesmoriarty/forward-proxy/blob/main/CHANGELOG.md'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']
end
