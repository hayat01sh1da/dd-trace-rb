# frozen_string_literal: true

require 'datadog/tracing/contrib/support/spec_helper'
require 'datadog/appsec/spec_helper'
require 'rack/test'

require 'faraday'
require 'datadog/tracing'
require 'datadog/appsec'

RSpec.describe 'Faraday SSRF Injection' do
  include Rack::Test::Methods

  before do
    Datadog.configure do |c|
      c.tracing.enabled = true
      c.tracing.instrument :rack
      c.tracing.instrument :http

      c.appsec.enabled = true
      c.appsec.instrument :rack
      c.appsec.instrument :faraday

      c.appsec.ruleset = {
        rules: [
          {
            id: 'rasp-934-100',
            name: 'Server-side request forgery exploit',
            tags: {
              type: 'ssrf',
              category: 'vulnerability_trigger',
              cwe: '918',
              capec: '1000/225/115/664',
              confidence: '0',
              module: 'rasp'
            },
            conditions: [
              {
                parameters: {
                  resource: [{address: 'server.io.net.url'}],
                  params: [
                    {address: 'server.request.query'},
                    {address: 'server.request.body'},
                    {address: 'server.request.path_params'},
                    {address: 'grpc.server.request.message'},
                    {address: 'graphql.server.all_resolvers'},
                    {address: 'graphql.server.resolver'}
                  ]
                },
                operator: 'ssrf_detector'
              }
            ],
            transformers: [],
            on_match: ['block']
          }
        ]
      }

      c.remote.enabled = false
    end

    allow_any_instance_of(Datadog::Tracing::Transport::HTTP::Client).to receive(:send_request)
  end

  after do
    Datadog.configuration.reset!
    Datadog.registry[:rack].reset_configuration!
  end

  let(:app) do
    stack = Rack::Builder.new do
      use Datadog::Tracing::Contrib::Rack::TraceMiddleware
      use Datadog::AppSec::Contrib::Rack::RequestMiddleware

      map '/ssrf' do
        run(
          lambda do |env|
            request = Rack::Request.new(env)
            client = Faraday.new("http://#{request.params["url"]}") do |faraday|
              faraday.adapter(:test) do |stub|
                stub.get('/') { |_| [200, {}, 'OK'] }
              end
            end
            response = client.get('/')

            [200, {'Content-Type' => 'application/json'}, [response.status]]
          end
        )
      end
    end

    stack.to_app
  end

  let(:http_service_entry_span) do
    Datadog::Tracing::Transport::TraceFormatter.format!(trace)
    spans.find { |s| s.name == 'rack.request' }
  end

  context 'when request params contain SSRF attack' do
    before do
      get('/ssrf', {'url' => '169.254.169.254'}, {'REMOTE_ADDR' => '127.0.0.1'})
    end

    it { expect(last_response).to be_forbidden }
  end

  context 'when request params do not contain SSRF attack' do
    before do
      get('/ssrf', {'url' => 'example.com'}, {'REMOTE_ADDR' => '127.0.0.1'})
    end

    it { expect(last_response).to be_ok }
  end
end
