require 'socket'
require 'netstring'
module JRPC
  class NetstringTcpSocket < ::TCPSocket
    def send_string(request)
      send Netstring.dump(request.to_s), 0
    end

    def receive_string
      length = get_msg_length
      response = recv(length)
      raise Exception.new('invalid response. missed comma as terminator') if response[-1] != ','
      response.chomp(',')
    end

    def set_timeout(timeout)
      seconds = Integer(timeout)
      microseconds = Integer((timeout-seconds)*1_000_000)
      packed_structure = [seconds, microseconds].pack('l_2') # structure with the number of seconds and microseconds
      setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, packed_structure)
    end

    private

    def get_msg_length
      length = ''
      while true do
        character = recv(1)
        break if character == ':'
        length += character
      end

      Integer(length)+1
    end
  end
end
