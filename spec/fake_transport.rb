class FakeTransport
  attr_reader :read_timeout, :write_timeout

  def initialize(params = {})
    @read_timeout = params.fetch(:read_timeout, 60.0).to_f
    @write_timeout = params.fetch(:write_timeout, 60.0).to_f
  end

  def connect; end

  def write(_, write_timeout = nil)
    @write_timeout = write_timeout if write_timeout
  end

  def read(_, buffer, read_timeout = nil)
    @read_timeout = read_timeout if read_timeout
    buffer << @response
  end

  def response=(str)
    @response = str + ','
  end
end
