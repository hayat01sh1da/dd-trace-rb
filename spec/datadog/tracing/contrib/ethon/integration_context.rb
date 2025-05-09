require 'webrick'
require 'spec/support/thread_helpers'

RSpec.shared_context 'integration context' do
  http_server do |http_server|
    http_server.mount_proc '/' do |req, res|
      sleep(0.001) if req.query['simulate_timeout']
      res.status = (req.query['status'] || req.body['status']).to_i
      if req.query['return_headers']
        headers = {}
        req.each do |header_name|
          headers[header_name] = req.header[header_name]
        end
        res.body = JSON.generate(headers: headers)
      else
        res.body = 'response'
      end
    end
  end

  let(:host) { 'localhost' }
  let(:status) { '200' }
  let(:path) { '/sample/path' }
  let(:port) { http_server_port }
  let(:method) { 'GET' }
  let(:simulate_timeout) { false }
  let(:timeout) { 5 }
  let(:return_headers) { false }
  let(:query) do
    query = { status: status }
    query[:return_headers] = 'true' if return_headers
    query[:simulate_timeout] = 'true' if simulate_timeout
  end
  let(:url) do
    url = "http://#{host}:#{http_server_port}#{path}?"
    url += "status=#{status}&" if status
    url += 'return_headers=true&' if return_headers
    url += 'simulate_timeout=true' if simulate_timeout
    url
  end

  let(:configuration_options) { {} }

  before do
    Datadog.configure do |c|
      c.tracing.instrument :ethon, configuration_options
    end
  end

  around do |example|
    # Reset before and after each example; don't allow global state to linger.
    Datadog.registry[:ethon].reset_configuration!
    example.run
    Datadog.registry[:ethon].reset_configuration!
  end
end
