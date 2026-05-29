# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'jrpc/version'

Gem::Specification.new do |spec|
  spec.name          = 'jrpc'
  spec.version       = JRPC::VERSION
  spec.authors       = ['Denis Talakevich']
  spec.email         = ['senid231@gmail.com']

  spec.summary       = 'JSON RPC client'
  spec.description   = 'JSON RPC client over TCP'
  spec.homepage      = 'https://github.com/didww/jrpc'
  spec.license       = 'MIT'

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.3'

  spec.add_dependency 'concurrent-ruby', '~> 1.2'
  spec.add_dependency 'logger'

  spec.executables << 'jrpc'
  spec.executables << 'jrpc-shell'

  spec.add_development_dependency 'bundler'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
end
