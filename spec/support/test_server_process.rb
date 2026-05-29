# frozen_string_literal: true

require 'rbconfig'

# Spawns spec/test_server.rb once for the whole suite and exposes its port.
# Started lazily on first use and reaped via at_exit, so the integration specs
# need no before(:all)/after(:all) hooks (which rubocop-rspec discourages).
module TestServerProcess
  module_function

  def port
    start! unless @io
    @port
  end

  def start!
    server_path = File.expand_path('../test_server.rb', __dir__)
    @io = IO.popen([RbConfig.ruby, server_path], 'r')
    @pid = @io.pid

    line = @io.gets&.chomp
    raise "test server did not announce a port (got: #{line.inspect})" unless line&.match?(/\APORT=\d+\z/)

    @port = line[/\d+/].to_i
    at_exit { stop! }
  end

  def stop!
    return unless @pid

    begin
      Process.kill('TERM', @pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.wait(@pid)
    rescue Errno::ECHILD
      nil
    end
    @io&.close
    @pid = nil
  end
end
