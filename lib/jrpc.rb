# frozen_string_literal: true

require 'socket'
require 'json'
require 'concurrent'
require 'jrpc/version'
require 'jrpc/errors'
require 'jrpc/id_generator'
require 'jrpc/message'
require 'jrpc/payload_logging'
require 'jrpc/transport'
require 'jrpc/simple_client'
require 'jrpc/shared_client/ticket'
require 'jrpc/shared_client/registry'
require 'jrpc/shared_client/outbound_queue'
require 'jrpc/shared_client/transport_loop'
require 'jrpc/shared_client'

module JRPC
  JSON_RPC_VERSION = '2.0'
end
