# frozen_string_literal: true

if ENV['CI'] == 'true'
  require 'simplecov'
  require 'simplecov-cobertura'

  SimpleCov.start do
    enable_coverage :branch
    minimum_coverage line: 90, branch: 80
    add_filter '/spec/'
    formatter SimpleCov::Formatter::MultiFormatter.new(
      [
        SimpleCov::Formatter::HTMLFormatter,
        SimpleCov::Formatter::CoberturaFormatter
      ]
    )
  end
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'jrpc'

Dir[File.expand_path('support/**/*.rb', __dir__)].each { |f| require f }
