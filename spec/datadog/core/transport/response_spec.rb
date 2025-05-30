require 'spec_helper'

require 'datadog/core/transport/response'

RSpec.describe Datadog::Core::Transport::Response do
  context 'when implemented by a class' do
    subject(:response) { response_class.new }

    let(:response_class) do
      stub_const('TestResponse', Class.new { include Datadog::Core::Transport::Response })
    end

    describe '#payload' do
      subject(:payload) { response.payload }

      it { is_expected.to be nil }
    end

    describe '#ok?' do
      subject(:ok?) { response.ok? }

      it { is_expected.to be nil }
    end

    describe '#unsupported?' do
      subject(:unsupported?) { response.unsupported? }

      it { is_expected.to be nil }
    end

    describe '#not_found?' do
      subject(:not_found?) { response.not_found? }

      it { is_expected.to be nil }
    end

    describe '#client_error?' do
      subject(:client_error?) { response.client_error? }

      it { is_expected.to be nil }
    end

    describe '#server_error?' do
      subject(:server_error?) { response.server_error? }

      it { is_expected.to be nil }
    end

    describe '#internal_error?' do
      subject(:internal_error?) { response.internal_error? }

      it { is_expected.to be nil }
    end
  end
end

RSpec.describe Datadog::Core::Transport::InternalErrorResponse do
  subject(:response) { described_class.new(error) }

  let(:error) { instance_double(StandardError) }

  describe '#initialize' do
    it { is_expected.to have_attributes(error: error) }
  end

  describe '#internal_error?' do
    subject(:internal_error?) { response.internal_error? }

    it { is_expected.to be true }
  end

  describe '#to_s' do
    it 'includes the causing exception' do
      expect(response.to_s).to match(/StandardError/)
    end
  end
end
