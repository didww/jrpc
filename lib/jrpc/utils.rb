module JRPC
  class Utils

    def self.truncate(string, length, ommiter = '...')
      "#{string[0..length]}#{ommiter if string.length > length}"
    end

  end
end
