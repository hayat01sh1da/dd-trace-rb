require 'spec_helper'

require 'datadog'
require 'datadog/tracing/transport/http/client'

RSpec.describe Datadog::Tracing::Transport::HTTP::Client do
  let(:logger) { logger_allowing_debug }
  let(:api) { instance_double(Datadog::Tracing::Transport::HTTP::Traces::API::Instance) }
  subject(:client) { described_class.new(api, logger: logger) }

  describe '#initialize' do
    it { is_expected.to be_a_kind_of(Datadog::Tracing::Transport::HTTP::Statistics) }
    it { is_expected.to have_attributes(api: api) }
  end

  describe '#send_request' do
    subject(:send_request) { client.send_request(request, &block) }

    let(:request) { instance_double(Datadog::Core::Transport::Request) }
    let(:response_class) { stub_const('TestResponse', Class.new { include Datadog::Core::Transport::HTTP::Response }) }
    let(:response) { instance_double(response_class, code: double('status code')) }

    before { allow(Datadog.health_metrics).to receive(:send_metrics) }

    context 'given a block' do
      let(:handler) { double }
      let(:block) do
        proc do |api, env|
          handler.api(api)
          handler.env(env)
          handler.response
        end
      end

      # Configure the handler
      before do
        allow(handler).to receive(:api)
        allow(handler).to receive(:env)
        allow(handler).to receive(:response).and_return(response)
      end

      context 'which returns an OK response' do
        before do
          allow(response).to receive(:not_found?).and_return(false)
          allow(response).to receive(:unsupported?).and_return(false)

          expect(client).to receive(:update_stats_from_response!)
            .with(response)
        end

        it 'sends to only the current API once' do
          is_expected.to eq(response)
          expect(handler).to have_received(:api).with(api).once
          expect(handler).to have_received(:env).with(kind_of(Datadog::Core::Transport::HTTP::Env)).once
        end
      end

      context 'which raises an error' do
        let(:error_class) { stub_const('TestError', Class.new(StandardError)) }
        let(:logger) { instance_double(Datadog::Core::Logger) }

        before do
          allow(handler).to receive(:response).and_raise(error_class)
          allow(Datadog).to receive(:logger).and_return(logger)
          allow(logger).to receive(:debug)
          allow(logger).to receive(:error)
        end

        it 'makes only one attempt and returns an internal error response' do
          expect(client).to receive(:update_stats_from_exception!)
            .with(kind_of(error_class))

          is_expected.to be_a_kind_of(Datadog::Core::Transport::InternalErrorResponse)
          expect(send_request.error).to be_a_kind_of(error_class)
          expect(handler).to have_received(:api).with(api).once

          # Check log was written to appropriately
          expect(logger).to have_received(:error).once
          expect(logger).to_not have_received(:debug)
        end

        context 'twice consecutively' do
          subject(:send_request) do
            client.send_request(request, &block)
            client.send_request(request, &block)
          end

          before do
            expect(client).to receive(:update_stats_from_exception!).twice do |exception|
              @count ||= 0
              @count += 1

              expect(exception).to be_a_kind_of(error_class)
              allow(client.stats).to receive(:consecutive_errors)
                .and_return(@count)
            end
          end

          it 'makes only one attempt per request and returns an internal error response' do
            is_expected.to be_a_kind_of(Datadog::Core::Transport::InternalErrorResponse)
            expect(send_request.error).to be_a_kind_of(error_class)
            expect(handler).to have_received(:api).with(api).twice

            # Check log was written to appropriately
            expect(logger).to have_received(:error).once
            expect(logger).to have_received(:debug).once
          end
        end
      end
    end
  end

  describe '#build_env' do
    subject(:env) { client.build_env(request) }

    let(:request) { instance_double(Datadog::Core::Transport::Request) }

    it 'returns a Datadog::Core::Transport::HTTP::Env' do
      is_expected.to be_a_kind_of(Datadog::Core::Transport::HTTP::Env)
      expect(env.request).to be request
    end
  end
end
