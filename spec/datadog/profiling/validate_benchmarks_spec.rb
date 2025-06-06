require "datadog/profiling/spec_helper"

RSpec.describe "Profiling benchmarks", :memcheck_valgrind_skip do
  before { skip_if_profiling_not_supported(self) }

  around do |example|
    ClimateControl.modify("VALIDATE_BENCHMARK" => "true") do
      example.run
    end
  end

  benchmarks_to_validate = [
    "profiling_allocation",
    "profiling_gc",
    "profiling_hold_resume_interruptions",
    "profiling_http_transport",
    "profiling_memory_sample_serialize",
    "profiling_sample_loop_v2",
    "profiling_sample_serialize",
    "profiling_sample_gvl",
    "profiling_string_storage_intern",
  ].freeze

  benchmarks_to_validate.each do |benchmark|
    describe benchmark do
      it("runs without raising errors") { expect_in_fork { load "./benchmarks/#{benchmark}.rb" } }
    end
  end

  # This test validates that we don't forget to add new benchmarks to benchmarks_to_validate
  it "tests all expected benchmarks in the benchmarks folder" do
    all_benchmarks = Dir["./benchmarks/profiling_*"].map { |it| it.gsub("./benchmarks/", "").gsub(".rb", "") }

    expect(benchmarks_to_validate).to contain_exactly(*all_benchmarks)
  end
end
