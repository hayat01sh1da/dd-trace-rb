require 'datadog/tracing/contrib/support/spec_helper'

require 'datadog/tracing/contrib/grpc'

RSpec.describe Datadog::Tracing::Contrib::GRPC do
  context 'integration test' do
    before { Datadog.configure {} }

    let(:config) { Datadog.configuration }

    describe '#inject' do
      subject(:inject) { described_class.inject(digest, data) }
      let(:trace_id) { Datadog::Tracing::Utils::TraceId.next_id }
      let(:span_id) { Datadog::Tracing::Utils.next_id }
      let(:digest) do
        Datadog::Tracing::TraceDigest.new(trace_id: trace_id, span_id: span_id, baggage: { 'key' => 'value' })
      end
      let(:data) { {} }

      it 'injects distributed headers' do
        inject
        expect(data).to include('x-datadog-trace-id')
        expect(data).to include('x-datadog-parent-id')
        expect(data).to include('baggage')
      end
    end

    describe '#extract' do
      subject(:extract) { described_class.extract(data) }

      let(:data) { { 'x-datadog-trace-id' => '1', 'x-datadog-parent-id' => '2', 'baggage' => 'key=value' } }

      it 'extracts distributed headers' do
        is_expected.to be_a_kind_of(Datadog::Tracing::TraceDigest)
      end
    end
  end
end
