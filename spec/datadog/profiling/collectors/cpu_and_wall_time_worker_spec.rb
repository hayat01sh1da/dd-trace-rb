require "datadog/profiling/spec_helper"

require "datadog/profiling/collectors/cpu_and_wall_time_worker"

RSpec.describe Datadog::Profiling::Collectors::CpuAndWallTimeWorker do
  before { skip_if_profiling_not_supported(self) }

  let(:endpoint_collection_enabled) { true }
  let(:gc_profiling_enabled) { true }
  let(:allocation_profiling_enabled) { false }
  let(:heap_profiling_enabled) { false }
  let(:recorder) do
    Datadog::Profiling::StackRecorder.for_testing(
      alloc_samples_enabled: true,
      heap_samples_enabled: heap_profiling_enabled,
      heap_size_enabled: heap_profiling_enabled,
      **stack_recorder_options,
    )
  end
  let(:no_signals_workaround_enabled) { false }
  let(:timeline_enabled) { false }
  let(:options) { {} }
  let(:stack_recorder_options) { {} }
  let(:allocation_counting_enabled) { false }
  let(:gvl_profiling_enabled) { false }
  let(:sighandler_sampling_enabled) { false }
  let(:worker_settings) do
    {
      gc_profiling_enabled: gc_profiling_enabled,
      no_signals_workaround_enabled: no_signals_workaround_enabled,
      thread_context_collector: build_thread_context_collector(recorder),
      dynamic_sampling_rate_overhead_target_percentage: 2.0,
      allocation_profiling_enabled: allocation_profiling_enabled,
      allocation_counting_enabled: allocation_counting_enabled,
      gvl_profiling_enabled: gvl_profiling_enabled,
      sighandler_sampling_enabled: sighandler_sampling_enabled,
      **options
    }
  end

  subject(:cpu_and_wall_time_worker) { described_class.new(**worker_settings, **options) }

  describe ".new" do
    it "creates the garbage collection tracepoint in the disabled state" do
      expect(described_class::Testing._native_gc_tracepoint(cpu_and_wall_time_worker)).to_not be_enabled
    end

    [true, false].each do |value|
      context "when endpoint_collection_enabled is #{value}" do
        let(:endpoint_collection_enabled) { value }

        it "initializes the ThreadContext collector with endpoint_collection_enabled: #{value}" do
          expect(Datadog::Profiling::Collectors::ThreadContext)
            .to receive(:new).with(hash_including(endpoint_collection_enabled: value)).and_call_original

          cpu_and_wall_time_worker
        end
      end

      context "when timeline_enabled is #{value}" do
        let(:timeline_enabled) { value }

        it "initializes the ThreadContext collector with timeline_enabled: #{value}" do
          expect(Datadog::Profiling::Collectors::ThreadContext)
            .to receive(:new).with(hash_including(timeline_enabled: value)).and_call_original

          cpu_and_wall_time_worker
        end
      end
    end
  end

  describe "#start" do
    let(:expected_worker_initialization_error) { nil }

    subject(:start) do
      cpu_and_wall_time_worker.start
      wait_until_running
    end

    after do
      cpu_and_wall_time_worker.stop
    end

    it "creates a new thread" do
      start

      expect(Thread.list.map(&:name)).to include(described_class.name)
    end

    # See https://github.com/puma/puma/blob/32e011ab9e029c757823efb068358ed255fb7ef4/lib/puma/cluster.rb#L353-L359
    it "marks the new thread as fork-safe" do
      start

      expect(cpu_and_wall_time_worker.instance_variable_get(:@worker_thread).thread_variable_get(:fork_safe)).to be true
    end

    it "does not create a second thread if start is called again" do
      start

      expect(Thread).to_not receive(:new)

      cpu_and_wall_time_worker.start
    end

    it "does not allow other instances of the CpuAndWallTimeWorker to start" do
      start

      allow(Datadog.logger).to receive(:warn)

      another_instance = build_another_instance
      another_instance.start

      exception = try_wait_until(backoff: 0.01) { another_instance.send(:failure_exception) }

      expect(exception.message).to include "another instance"

      another_instance.stop
    end

    it "installs the profiling SIGPROF signal handler" do
      start

      expect(described_class::Testing._native_current_sigprof_signal_handler).to be :profiling
    end

    context "when gc_profiling_enabled is true" do
      let(:gc_profiling_enabled) { true }

      it "enables the garbage collection tracepoint" do
        start

        expect(described_class::Testing._native_gc_tracepoint(cpu_and_wall_time_worker)).to be_enabled
      end
    end

    context "when gc_profiling_enabled is false" do
      let(:gc_profiling_enabled) { false }

      it "does not enable the garbage collection tracepoint" do
        start

        expect(described_class::Testing._native_gc_tracepoint(cpu_and_wall_time_worker)).to_not be_enabled
      end
    end

    context "when gvl_profiling_enabled is true" do
      before { skip_if_gvl_profiling_not_supported(self) }

      let(:gvl_profiling_enabled) { true }

      it "enables the gvl profiling hook" do
        start

        expect(described_class::Testing._native_gvl_profiling_hook_active(cpu_and_wall_time_worker)).to be true
      end
    end

    context "when gvl_profiling_enabled is true on an unsupported Ruby" do
      before { skip "Behavior does not apply to current Ruby version" if RUBY_VERSION >= "3.2." }

      let(:gvl_profiling_enabled) { true }

      it do
        expect(Datadog.logger).to receive(:warn).with(/GVL profiling is not supported/)
        expect(Datadog::Core::Telemetry::Logger).to receive(:report)
        proc_called = Queue.new

        cpu_and_wall_time_worker.start(on_failure_proc: proc { proc_called << true })

        proc_called.pop
      end
    end

    context "when gvl_profiling_enabled is false" do
      let(:gvl_profiling_enabled) { false }

      it "does not enable the gvl profiling hook" do
        start

        expect(described_class::Testing._native_gvl_profiling_hook_active(cpu_and_wall_time_worker)).to be false
      end
    end

    context "when a previous signal handler existed" do
      before do
        described_class::Testing._native_install_testing_signal_handler
        expect(described_class::Testing._native_current_sigprof_signal_handler).to be :other

        allow(Datadog.logger).to receive(:warn)
      end

      after do
        described_class::Testing._native_remove_testing_signal_handler
      end

      it "does not start the sampling loop" do
        cpu_and_wall_time_worker.start

        exception = try_wait_until(backoff: 0.01) { cpu_and_wall_time_worker.send(:failure_exception) }

        expect(exception.message).to include "pre-existing SIGPROF"
      end

      it "leaves the existing signal handler in place" do
        cpu_and_wall_time_worker.start

        try_wait_until(backoff: 0.01) { cpu_and_wall_time_worker.send(:failure_exception) }

        expect(described_class::Testing._native_current_sigprof_signal_handler).to be :other
      end
    end

    context "sampling of active threads" do
      # This option makes sure our samples are taken via thread interruptions (and not via idle sampling).
      # See native bits for more details.
      let(:options) { {**super(), skip_idle_samples_for_testing: true} }

      it "triggers sampling and records the results", :memcheck_valgrind_skip do
        start

        all_samples = loop_until do
          samples = samples_from_pprof_without_gc_and_overhead(recorder.serialize!)
          samples if samples.any?
        end

        expect(samples_for_thread(all_samples, Thread.current)).to_not be_empty
      end

      it(
        "keeps statistics on how many samples were triggered by the background thread, " \
        "as well as how many samples were requested from the VM",
        :memcheck_valgrind_skip,
      ) do
        start

        all_samples = loop_until do
          samples = samples_from_pprof_without_gc_and_overhead(recorder.serialize!)
          samples if samples.any?
        end

        cpu_and_wall_time_worker.stop

        sample_count =
          samples_for_thread(all_samples, Thread.current)
            .map { |it| it.values.fetch(:"cpu-samples") }
            .reduce(:+)

        stats = cpu_and_wall_time_worker.stats

        expect(sample_count).to be > 0
        expect(stats.fetch(:signal_handler_enqueued_sample)).to be >= sample_count
        expect(stats.fetch(:trigger_sample_attempts)).to be >= stats.fetch(:signal_handler_enqueued_sample)
        # Validate that we actually tried to sample via thread interruption, and not other means
        expect(stats.fetch(:interrupt_thread_attempts)).to be > 0
      end
    end

    it "keeps statistics on how long sampling is taking" do
      start

      try_wait_until do
        samples = samples_from_pprof_without_gc_and_overhead(recorder.serialize!)
        samples if samples.any?
      end

      cpu_and_wall_time_worker.stop

      stats = cpu_and_wall_time_worker.stats

      sampling_time_ns_min = stats.fetch(:cpu_sampling_time_ns_min)
      sampling_time_ns_max = stats.fetch(:cpu_sampling_time_ns_max)
      sampling_time_ns_total = stats.fetch(:cpu_sampling_time_ns_total)
      sampling_time_ns_avg = stats.fetch(:cpu_sampling_time_ns_avg)

      expect(sampling_time_ns_min).to be <= sampling_time_ns_max
      expect(sampling_time_ns_max).to be <= sampling_time_ns_total
      expect(sampling_time_ns_avg).to be >= sampling_time_ns_min
      one_second_in_ns = 1_000_000_000
      expect(sampling_time_ns_max).to be < one_second_in_ns, "A single sample should not take longer than 1s, #{stats}"
    end

    context "with allocation profiling enabled" do
      # We need this otherwise allocations_during_sample will never change
      let(:allocation_profiling_enabled) { true }

      it "does not allocate Ruby objects during the regular operation of sampling" do
        # The intention of this test is to warn us if we accidentally trigger object allocations during "happy path"
        # sampling.
        # Note that when something does go wrong during sampling, we do allocate exceptions (and then raise them).

        start

        try_wait_until do
          samples = samples_from_pprof_without_gc_and_overhead(recorder.serialize!)
          samples if samples.any?
        end

        cpu_and_wall_time_worker.stop

        stats = cpu_and_wall_time_worker.stats

        expect(stats).to include(allocations_during_sample: 0)
      end
    end

    it "records garbage collection cycles" do
      start

      described_class::Testing._native_trigger_sample

      5.times do
        Thread.pass
        GC.start
        Thread.pass
      end

      cpu_and_wall_time_worker.stop

      all_samples = samples_from_pprof(recorder.serialize!)

      gc_sample = all_samples.find { |sample| sample.labels[:"gc cause"] == "GC.start()" }

      expect(gc_sample.labels).to match a_hash_including(
        state: "had cpu",
        "thread id": "GC",
        "thread name": "Garbage Collection",
        event: "gc",
        "gc reason": an_instance_of(String),
        "gc cause": "GC.start()",
        "gc type": "major",
      )
      expect(gc_sample.locations.first.path).to eq "Garbage Collection"
    end

    context "when the background thread dies without cleaning up (after Ruby forks)" do
      it "allows the CpuAndWallTimeWorker to be restarted" do
        start

        expect_in_fork do
          cpu_and_wall_time_worker.start
          wait_until_running
        end
      end

      it "allows a different instance of the CpuAndWallTimeWorker to be started" do
        start

        expect_in_fork do
          another_instance = build_another_instance
          another_instance.start

          another_instance.wait_until_running
        end
      end

      it "disables the existing gc_tracepoint before starting another CpuAndWallTimeWorker" do
        start

        expect(described_class::Testing._native_gc_tracepoint(cpu_and_wall_time_worker)).to be_enabled

        expect_in_fork do
          another_instance = build_another_instance
          another_instance.start

          another_instance.wait_until_running

          expect(described_class::Testing._native_gc_tracepoint(cpu_and_wall_time_worker)).to_not be_enabled
          expect(described_class::Testing._native_gc_tracepoint(another_instance)).to be_enabled
        end
      end
    end

    context "when main thread is sleeping but a background thread is working", :memcheck_valgrind_skip do
      let(:ready_queue) { Queue.new }
      let(:background_thread) do
        Thread.new do
          ready_queue << true
          i = 0
          loop { (i = (i + 1) % 2) }
        end
      end

      after do
        unless RSpec.current_example.skipped?
          background_thread.kill
          background_thread.join
        end
      end

      it "is able to sample even when the main thread is sleeping" do
        background_thread
        ready_queue.pop

        start
        wait_until_running

        sleep 0.1

        cpu_and_wall_time_worker.stop
        background_thread.kill

        result = samples_for_thread(samples_from_pprof_without_gc_and_overhead(recorder.serialize!), Thread.current)
        sample_count = result.map { |it| it.values.fetch(:"cpu-samples") }.reduce(:+)

        stats = cpu_and_wall_time_worker.stats

        trigger_sample_attempts = stats.fetch(:trigger_sample_attempts)
        signal_handler_enqueued_sample = stats.fetch(:signal_handler_enqueued_sample)

        expect(signal_handler_enqueued_sample.to_f / trigger_sample_attempts).to (be >= 0.6),
          "Expected at least 60% of signals to be delivered to correct thread (#{stats})"

        # Sanity checking

        # We're currently targeting 100 samples per second, so 5 in 100ms is a conservative approximation that hopefully
        # will not cause flakiness.
        # If this turns out to be flaky due to the dynamic sampling rate mechanism, it can be disabled like we do for
        # the test below.
        expect(sample_count).to be >= 5, "sample_count: #{sample_count}, stats: #{stats}"
        expect(trigger_sample_attempts).to be >= sample_count
      end

      context "when GVL profiling is enabled" do
        before { skip_if_gvl_profiling_not_supported(self) }

        let(:gvl_profiling_enabled) { true }

        let(:timeline_enabled) { true }
        let(:ready_queue_2) { Queue.new }
        let(:background_thread_affected_by_gvl_contention) do
          Thread.new do
            ready_queue_2 << true
            loop { Thread.pass }
          end
        end

        after do
          background_thread_affected_by_gvl_contention.kill
          background_thread_affected_by_gvl_contention.join
        end

        it "records Waiting for GVL samples" do
          background_thread_affected_by_gvl_contention
          ready_queue_2.pop

          start
          wait_until_running

          background_thread
          ready_queue.pop

          sleep 0.2

          threads = Thread.list

          cpu_and_wall_time_worker.stop

          background_thread.kill
          background_thread_affected_by_gvl_contention.kill

          samples = samples_for_thread(
            samples_from_pprof_without_gc_and_overhead(recorder.serialize!),
            background_thread_affected_by_gvl_contention
          ).sort_by { |s| s.labels.fetch(:end_timestamp_ns) }

          thread_activity_time =
            samples
              .group_by { |s| s.labels[:state] }
              .map { |state, state_samples| [state, state_samples.sum { |s| s.values.fetch(:"wall-time") }] }.to_h

          # Because the background_thread_affected_by_gvl_contention starts BEFORE the profiler, the first few samples
          # will have a sequence of unknown states because the profiler may have missed the beginning of the
          # Waiting for GVL (and cannot categorize the state yet).
          #
          # In these cases, the pattern will be "unknown (one or more times), had cpu, waiting for gvl".
          #
          # In rare cases, we observe the background_thread_affected_by_gvl_contention just as it's starting the
          # Waiting for GVL. Because "starting the Waiting for GVL" still uses a bit of CPU, we'll see
          # "unknown, had cpu, unknown (one or more times), had cpu, waiting for gvl".
          #
          # So that the below assertions make sense (and are not flaky), we drop these first few samples from our
          # consideration

          found_first_cpu = false
          missed_by_profiler_time =
            samples
              .take_while do |s|
                if s.labels[:state] == "unknown"
                  true
                elsif s.labels[:state] == "had cpu" && !found_first_cpu
                  found_first_cpu = true
                  true
                end
              end.sum { |sample| sample.values.fetch(:"wall-time") }

          total_time = samples.sum { |sample| sample.values.fetch(:"wall-time") } - missed_by_profiler_time
          waiting_for_gvl_samples = samples.select { |sample| sample.labels[:state] == "waiting for gvl" }
          waiting_for_gvl_time = waiting_for_gvl_samples.sum { |sample| sample.values.fetch(:"wall-time") }

          debug_failures = {
            thread_activity_time: thread_activity_time,
            missed_by_profiler_time: missed_by_profiler_time,
            total_time: total_time,
            waiting_for_gvl_time: waiting_for_gvl_time,
            sample_states: samples.map { |s| s.labels[:state] },
            samples: samples.map { |s| [s.values, s.labels] },
            threads: threads.map { |t| [t.inspect, t.object_id] }
          }

          # The background thread should spend almost all of its time waiting to run (since when it gets to run
          # it just passes and starts waiting)

          # This test should run for at least 200ms, which is how long we sleep for
          # (unless somehow the missed_by_profiler_time is too big?)
          expect(total_time).to be >= 200_000_000
          expect(waiting_for_gvl_time).to be < total_time
          expect(waiting_for_gvl_time).to be_within(5).percent_of(total_time),
            "Expected waiting_for_gvl_time to be close to total_time, debug_failures: #{debug_failures}"

          expect(cpu_and_wall_time_worker.stats).to match(
            hash_including(
              after_gvl_running: be > 0,
              gvl_sampling_time_ns_min: be > 0,
              gvl_sampling_time_ns_max: be > 0,
              gvl_sampling_time_ns_total: be > 0,
              gvl_sampling_time_ns_avg: be > 0,
            )
          )
        end

        context "when 'Waiting for GVL' periods are below waiting_for_gvl_threshold_ns" do
          let(:options) do
            ten_seconds_as_ns = 1_000_000_000
            collector = build_thread_context_collector(recorder, waiting_for_gvl_threshold_ns: ten_seconds_as_ns)

            {thread_context_collector: collector}
          end

          it "does not trigger extra samples" do
            background_thread_affected_by_gvl_contention
            ready_queue_2.pop

            start
            wait_until_running

            sleep 0.1
            background_thread_affected_by_gvl_contention.kill

            cpu_and_wall_time_worker.stop

            # Note: There may still be "Waiting for GVL" samples in the output, but these samples will come from the
            # periodic cpu/wall-sampling, not samples directly triggered by the end of a "Waiting for GVL" period.

            expect(cpu_and_wall_time_worker.stats.fetch(:gvl_dont_sample)).to be > 0

            expect(cpu_and_wall_time_worker.stats).to match(
              hash_including(
                after_gvl_running: 0,
                gvl_sampling_time_ns_min: nil,
                gvl_sampling_time_ns_max: nil,
                gvl_sampling_time_ns_total: nil,
                gvl_sampling_time_ns_avg: nil,
              )
            )
          end
        end
      end
    end

    context "when all threads are sleeping (no thread holds the Global VM Lock)" do
      let(:options) { {dynamic_sampling_rate_enabled: false} }

      before do
        expect(Datadog.logger).to receive(:warn).with(/dynamic sampling rate disabled/)
        expect(Datadog::Core::Telemetry::Logger).to receive(:error).with(/dynamic sampling rate disabled/)
      end

      it "is able to sample even when all threads are sleeping" do
        start
        wait_until_running

        sleep 0.2

        cpu_and_wall_time_worker.stop

        all_samples = samples_from_pprof_without_gc_and_overhead(recorder.serialize!)
        result = samples_for_thread(all_samples, Thread.current)
        sample_count = result.map { |it| it.values.fetch(:"cpu-samples") }.reduce(:+)

        stats = cpu_and_wall_time_worker.stats
        debug_failures = {thread_list: Thread.list, all_samples: all_samples}

        trigger_sample_attempts = stats.fetch(:trigger_sample_attempts)
        simulated_signal_delivery = stats.fetch(:simulated_signal_delivery)

        expect(simulated_signal_delivery.to_f / trigger_sample_attempts).to (be >= 0.8),
          "Expected at least 80% of signals to be simulated, stats: #{stats}, debug_failures: #{debug_failures}"

        # Sanity checking

        # We're currently targeting 100 samples per second (aka ~20 in the 0.2 period above), so expecting 8 samples
        # will hopefully not cause flakiness. But this test has been flaky in the past so... Ping @ivoanjo if it happens
        # again.
        #
        expect(sample_count).to be >= 8, "sample_count: #{sample_count}, stats: #{stats}, debug_failures: #{debug_failures}"

        if RUBY_VERSION >= "3.3.0"
          expect(trigger_sample_attempts).to be >= sample_count
        else
          # @ivoanjo: We've seen this assertion become flaky once in CI for Ruby 3.1, where
          # `trigger_sample_attempts` was 20 and `sample_count` was 21. This is unexpected since (at time of writing)
          # we always increment the counter before triggering a sample, so this should not be possible.
          #
          # After some head scratching, I'm convinced we might have seen another variant of the issue in
          # https://bugs.ruby-lang.org/issues/19991, going something like:
          # 1. There was an existing postponed job unrelated to profiling for execution
          # 2. Ruby dequeues the existing postponed job, but before it can be executed
          # 3. ...our signal arrives, and our call to `rb_postponed_job_register_one` clobbers the existing job
          # 4. Ruby then proceeds to execute what it thinks is the correct job, but it actually has been clobbered
          #    and it triggers a profiler sample
          # 5. Then Ruby notices there's a new job to execute, and triggers the profiler sample again
          # And both samples are taken because this test runs without dynamic sampling rate.
          #
          # To avoid the flakiness, I've added a dummy margin here but... yeah in practice this can happen as many times
          # as we try to sample.
          margin = 1
          expect(trigger_sample_attempts).to (be >= (sample_count - margin)),
            "sample_count: #{sample_count}, stats: #{stats}, debug_failures: #{debug_failures}"
        end
      end
    end

    context "when using the no signals workaround" do
      let(:no_signals_workaround_enabled) { true }

      it "always simulates signal delivery" do
        start

        all_samples = try_wait_until do
          samples = samples_from_pprof_without_gc_and_overhead(recorder.serialize!)
          samples if samples.any?
        end

        cpu_and_wall_time_worker.stop

        sample_count =
          samples_for_thread(all_samples, Thread.current)
            .map { |it| it.values.fetch(:"cpu-samples") }
            .reduce(:+)

        # Since we're reading the stats AFTER the worker is stopped, we expect a consistent view, as otherwise we
        # would have races (e.g. the stats could be changing as we're trying to read them, since it's on a background
        # thread that doesn't hold the Global VM Lock while mutating some of these values)
        stats = cpu_and_wall_time_worker.stats
        trigger_sample_attempts = stats.fetch(:trigger_sample_attempts)

        expect(sample_count).to be > 0
        expect(stats).to(
          match(
            a_hash_including(
              trigger_simulated_signal_delivery_attempts: trigger_sample_attempts,
              simulated_signal_delivery: trigger_sample_attempts,
              signal_handler_enqueued_sample: trigger_sample_attempts,
            )
          ),
          "**If you see this test flaking, please report it to @ivoanjo!**\n\n" \
          "sample_count: #{sample_count}, samples: #{all_samples}"
        )
      end
    end

    context "when allocation profiling is enabled" do
      let(:allocation_profiling_enabled) { true }
      let(:test_num_allocated_object) { 123 }
      # Explicitly disable dynamic sampling in these tests so we can deterministically verify
      # sample counts.
      let(:options) { {dynamic_sampling_rate_enabled: false} }

      before do
        allow(Datadog.logger).to receive(:warn)
        allow(Datadog.logger).to receive(:warn).with(/dynamic sampling rate disabled/)
      end

      it "records allocated objects" do
        stub_const("CpuAndWallTimeWorkerSpec::TestStruct", Struct.new(:foo))

        start

        test_num_allocated_object.times { CpuAndWallTimeWorkerSpec::TestStruct.new }
        allocation_line = __LINE__ - 1

        cpu_and_wall_time_worker.stop

        allocation_sample =
          samples_for_thread(samples_from_pprof(recorder.serialize!), Thread.current)
            .find { |s| s.labels[:"allocation class"] == "CpuAndWallTimeWorkerSpec::TestStruct" }

        expect(allocation_sample.values).to include("alloc-samples": test_num_allocated_object)
        # For Ruby 3.5 onwards, new is inlined into the bytecode of the caller and there's no "new"
        # frame at the top of the stack, see https://github.com/ruby/ruby/pull/13080
        expect((RUBY_VERSION >= "3.5.0") ? allocation_sample.locations[0] : allocation_sample.locations[1])
          .to match(have_attributes(base_label: "<top (required)>", path: __FILE__, lineno: allocation_line))
      end

      context "with dynamic_sampling_rate_enabled" do
        let(:options) { {dynamic_sampling_rate_enabled: true} }

        it "keeps statistics on how allocation sampling is doing" do
          stub_const("CpuAndWallTimeWorkerSpec::TestStruct", Struct.new(:foo))

          start

          test_num_allocated_object.times { CpuAndWallTimeWorkerSpec::TestStruct.new }

          cpu_and_wall_time_worker.stop

          stats = cpu_and_wall_time_worker.stats

          sampled = stats.fetch(:allocation_sampled)
          skipped = stats.fetch(:allocation_skipped)
          effective_rate = stats.fetch(:allocation_effective_sample_rate)
          sampling_time_ns_min = stats.fetch(:allocation_sampling_time_ns_min)
          sampling_time_ns_max = stats.fetch(:allocation_sampling_time_ns_max)
          sampling_time_ns_total = stats.fetch(:allocation_sampling_time_ns_total)
          sampling_time_ns_avg = stats.fetch(:allocation_sampling_time_ns_avg)

          expect(sampled).to be > 0
          expect(skipped).to be > 0
          expect(effective_rate).to be > 0
          expect(effective_rate).to be < 1
          expect(sampling_time_ns_min).to be <= sampling_time_ns_max
          expect(sampling_time_ns_max).to be <= sampling_time_ns_total
          expect(sampling_time_ns_avg).to be >= sampling_time_ns_min
          one_second_in_ns = 1_000_000_000
          expect(sampling_time_ns_max).to be < one_second_in_ns, "A single sample should not take longer than 1s, #{stats}"
        end

        # When large numbers of objects are allocated, the dynamic sampling rate kicks in, and we don't sample every
        # object.
        # We then assign a weight to every sample to compensate for this; to avoid bias, we have a limit on this weight,
        # and we clamp it if it goes over the limit.
        # But the total amount of allocations recorded should match the number we observed, and thus we record the
        # remainder above the clamped value as a separate "Skipped Samples" step.
        context "with a high allocation rate", :memcheck_valgrind_skip do
          let(:options) { {**super(), dynamic_sampling_rate_overhead_target_percentage: 0.1} }
          let(:thread_that_allocates_as_fast_as_possible) { Thread.new { loop { BasicObject.new } } }

          after do
            thread_that_allocates_as_fast_as_possible.kill
            thread_that_allocates_as_fast_as_possible.join
          end

          it "records skipped allocation samples when weights are clamped" do
            start

            # Trigger thread creation
            thread_that_allocates_as_fast_as_possible

            allocation_samples = try_wait_until do
              samples = samples_from_pprof(recorder.serialize!).select { |it| it.values[:"alloc-samples"] > 0 }
              samples if samples.any? { |it| it.labels[:"thread name"] == "Skipped Samples" }
            end

            # Stop thread earlier, since it will slow down the Ruby VM
            thread_that_allocates_as_fast_as_possible.kill
            thread_that_allocates_as_fast_as_possible.join

            cpu_and_wall_time_worker.stop

            expect(allocation_samples).to_not be_empty
          end
        end
      end

      context "when sampling optimized Ruby strings" do
        # Regression test: Some internal Ruby classes use a `rb_str_tmp_frozen_acquire` function which allocates a
        # weird "intermediate" string object that has its class pointer set to 0.
        #
        # When such an object gets sampled, we need to take care not to try to resolve its class name.
        #
        # In practice, this test is actually validating behavior of the `ThreadContext` collector, but we can only
        # really trigger this situation when using the allocation tracepoint, which lives in the `CpuAndWallTimeWorker`.
        it "does not crash" do
          start

          expect(Time.now.strftime(+"Potato")).to_not be nil
        end
      end

      context "T_IMEMO internal VM objects" do
        let(:something_that_triggers_creation_of_imemo_objects) do
          eval("proc { def self.foo; rand; end; foo }.call", binding, __FILE__, __LINE__)
        end

        context "on Ruby 2.x" do
          before { skip "Behavior only applies on Ruby 2.x" unless RUBY_VERSION.start_with?("2.") }

          it "records internal VM objects, not including their specific kind" do
            start

            something_that_triggers_creation_of_imemo_objects

            cpu_and_wall_time_worker.stop

            imemo_samples =
              samples_for_thread(samples_from_pprof(recorder.serialize!), Thread.current)
                .select { |s| s.labels.fetch(:"allocation class", "") == "(VM Internal, T_IMEMO)" }

            expect(imemo_samples.size).to be >= 1 # We should always get some T_IMEMO objects
          end
        end

        context "on Ruby 3.x" do
          before { skip "Behavior only applies on Ruby 3.x" if RUBY_VERSION.start_with?("2.") }

          it "records internal VM objects, including their specific kind" do
            start

            something_that_triggers_creation_of_imemo_objects

            cpu_and_wall_time_worker.stop

            imemo_samples =
              samples_for_thread(samples_from_pprof(recorder.serialize!), Thread.current)
                .select { |s| s.labels.fetch(:"allocation class", "").start_with?("(VM Internal, T_IMEMO") }

            expect(imemo_samples.size).to be >= 1 # We should always get some T_IMEMO objects

            # To avoid coupling too much on VM internals we check that at each of the found allocation classes are
            # a known member of the imemo_type enum (even if we don't exactly match on which one)
            expect(imemo_samples.map { |s| s.labels.fetch(:"allocation class") }).to all(
              match(
                /(env|cref|svar|throw_data|ifunc|memo|ment|iseq|tmpbuf|ast|parser_strterm|callinfo|callcache|constcache)/
              )
            )
          end
        end
      end
    end

    context "when allocation sampling is disabled" do
      let(:allocation_profiling_enabled) { false }

      it "does not record allocations" do
        stub_const("CpuAndWallTimeWorkerSpec::TestStruct", Struct.new(:foo))

        start

        123.times { CpuAndWallTimeWorkerSpec::TestStruct.new }

        cpu_and_wall_time_worker.stop

        expect(samples_from_pprof(recorder.serialize!).map(&:values)).to all(include("alloc-samples": 0))
      end
    end

    context "when heap profiling is enabled" do
      let(:allocation_profiling_enabled) { true }
      let(:heap_profiling_enabled) { true }
      let(:test_num_allocated_object) { 123 }
      # Explicitly disable dynamic sampling in these tests so we can deterministically verify
      # sample counts.
      let(:options) { {dynamic_sampling_rate_enabled: false} }

      before do
        skip "Heap profiling is only supported on Ruby >= 2.7" if RUBY_VERSION < "2.7"
        allow(Datadog.logger).to receive(:warn)
        expect(Datadog.logger).to receive(:warn).with(/dynamic sampling rate disabled/)
      end

      after do |example|
        # This is here to facilitate troubleshooting when this test fails. Otherwise
        # it's very hard to understand what may be happening.
        if example.exception
          cpu_and_wall_time_worker.stop

          puts("Heap recorder debugging info:")
          puts(Datadog::Profiling::StackRecorder::Testing._native_debug_heap_recorder(recorder))
        end
      end

      it "records live heap objects" do
        stub_const("CpuAndWallTimeWorkerSpec::TestStruct", Struct.new(:foo))

        start

        live_objects = Array.new(test_num_allocated_object)

        test_num_allocated_object.times { |i| live_objects[i] = CpuAndWallTimeWorkerSpec::TestStruct.new }
        allocation_line = __LINE__ - 1

        # Force a GC to happen here to ensure all the live_objects have age > 0.
        # Otherwise they wouldn't show up in the serialized pprof below
        GC.start

        cpu_and_wall_time_worker.stop

        current_method_name = caller_locations(0, 1).first.base_label

        # We can't just use find here because samples might have different gc age labels
        # if a gc happens to run in the middle of this test. Thus, we'll have to sum up
        # together the values of all matching samples.
        relevant_samples = samples_from_pprof(recorder.serialize!).select do |sample|
          # From Ruby 3.5 onwards, new is inlined into the bytecode of the caller and there's no "new"
          # frame at the top of the stack, see https://github.com/ruby/ruby/pull/13080
          allocation_trigger_frame = (RUBY_VERSION >= "3.5.0") ? sample.locations[0] : sample.locations[1]
          next unless allocation_trigger_frame

          allocation_trigger_frame.lineno == allocation_line &&
            allocation_trigger_frame.path == __FILE__ &&
            allocation_trigger_frame.base_label == current_method_name &&
            sample.labels[:"allocation class"] == "CpuAndWallTimeWorkerSpec::TestStruct" &&
            (sample.values[:"heap-live-samples"] || 0) > 0
        end

        total_samples = relevant_samples.map { |sample| sample.values[:"heap-live-samples"] || 0 }.reduce(:+)
        total_size = relevant_samples.map { |sample| sample.values[:"heap-live-size"] || 0 }.reduce(:+)

        expect(total_samples).to eq test_num_allocated_object

        expected_size_of_object = 40 # 40 is the size of a basic object and we have test_num_allocated_object of them

        # Starting with Ruby 3.5, the object_id counts towards the object's size
        if RUBY_VERSION >= "3.5.0"
          expected_size_of_object = 104

          expect(ObjectSpace.memsize_of(CpuAndWallTimeWorkerSpec::TestStruct.new.tap(&:object_id)))
            .to be expected_size_of_object
        end

        expect(total_size).to eq test_num_allocated_object * expected_size_of_object
      end

      describe "heap cleanup after GC" do
        let(:options) { {dynamic_sampling_rate_enabled: false} }

        let(:cleared_object_id) do
          stub_const("CpuAndWallTimeWorkerSpec::TestStruct", Struct.new(:foo))

          start

          # Force a full GC to make sure there's no incremental GC going on at this point
          GC.start

          test_object = CpuAndWallTimeWorkerSpec::TestStruct.new
          test_object_id = test_object.object_id

          expect(
            Datadog::Profiling::StackRecorder::Testing._native_is_object_recorded?(recorder, test_object_id)
          ).to be true

          # Let's replace the test_object reference with another object, so that the original one can be GC'd
          test_object = Object.new # rubocop:disable Lint/UselessAssignment

          # Force an update to happen on the next GC
          Datadog::Profiling::StackRecorder::Testing._native_heap_recorder_reset_last_update(recorder)

          GC.start

          test_object_id
        end

        context "when gc_profiling_enabled is enabled" do
          let(:gc_profiling_enabled) { true }

          context "when heap_clean_after_gc_enabled is enabled in the recorder" do
            let(:stack_recorder_options) { {**super(), heap_clean_after_gc_enabled: true} }

            it "removes live heap objects after GCs" do
              expect(
                Datadog::Profiling::StackRecorder::Testing._native_is_object_recorded?(recorder, cleared_object_id)
              ).to be false
            end
          end

          context "when heap_clean_after_gc_enabled is disabled in the recorder" do
            let(:stack_recorder_options) { {**super(), heap_clean_after_gc_enabled: false} }

            it "does not remove live heap objects after GCs" do
              expect(
                Datadog::Profiling::StackRecorder::Testing._native_is_object_recorded?(recorder, cleared_object_id)
              ).to be true
            end
          end
        end

        context "when GC profiling is disabled" do
          let(:gc_profiling_enabled) { false }

          it "does not remove live heap objects after minor GCs" do
            # The object is still being tracked!
            expect(
              Datadog::Profiling::StackRecorder::Testing._native_is_object_recorded?(recorder, cleared_object_id)
            ).to be true

            # Sanity checking: It stops being tracked after a serialization, proving it was indeed dead, we just hadn't
            # updated our state yet
            recorder.serialize!
            expect(
              Datadog::Profiling::StackRecorder::Testing._native_is_object_recorded?(recorder, cleared_object_id)
            ).to be false
          end
        end
      end
    end

    context "when heap profiling is disabled" do
      let(:heap_profiling_enabled) { false }

      it "does not record heap samples" do
        stub_const("CpuAndWallTimeWorkerSpec::TestStruct", Struct.new(:foo))

        start

        123.times { CpuAndWallTimeWorkerSpec::TestStruct.new }

        cpu_and_wall_time_worker.stop

        expect(samples_from_pprof(recorder.serialize!).select { |s| s.values.key?(:"heap-live-samples") }).to be_empty
      end
    end

    describe "sampling from signal handler", :memcheck_valgrind_skip do
      let(:options) { {dynamic_sampling_rate_enabled: false} }

      let(:sample_count) do
        samples_for_thread(samples_from_pprof_without_gc_and_overhead(recorder.serialize!), Thread.current)
          .map { |it| it.values.fetch(:"cpu-samples") }.reduce(:+)
      end
      let(:signal_handler_prepared_sample) { cpu_and_wall_time_worker.stats.fetch(:signal_handler_prepared_sample) }
      let(:signal_handler_enqueued_sample) { cpu_and_wall_time_worker.stats.fetch(:signal_handler_enqueued_sample) }

      before do
        allow(Datadog.logger).to receive(:warn).with(/dynamic sampling rate disabled/)
        allow(Datadog::Core::Telemetry::Logger).to receive(:error).with(/dynamic sampling rate disabled/)

        skip_if_signal_handler_sampling_not_supported

        start

        loop_until { cpu_and_wall_time_worker.stats.fetch(:signal_handler_enqueued_sample) >= 20 }

        cpu_and_wall_time_worker.stop

        expect(sample_count).to be > 0
        expect(sample_count).to be_within(20).percent_of(signal_handler_enqueued_sample)
      end

      context "when signal handler sampling is enabled" do
        let(:sighandler_sampling_enabled) { true }

        it "prepares samples in the signal handler" do
          expect(signal_handler_prepared_sample).to be > 0
          expect(signal_handler_prepared_sample).to be_within(20).percent_of(signal_handler_enqueued_sample)
        end
      end

      context "when signal handler sampling is disabled" do
        let(:sighandler_sampling_enabled) { false }

        it "does not prepare samples in the signal handler" do
          expect(signal_handler_prepared_sample).to be 0
        end
      end

      def skip_if_signal_handler_sampling_not_supported
        return unless sighandler_sampling_enabled

        ruby_version = Gem::Version.new(RUBY_VERSION)
        if ruby_version < Gem::Version.new("3.2.5") ||
            (ruby_version >= Gem::Version.new("3.3.0") && ruby_version < Gem::Version.new("3.3.4"))
          # In practice, many older Rubies are OK to sample from the signal handler, but for the purposes of testing
          # this is a safe simplification (these versions all include https://github.com/ruby/ruby/pull/11036)
          skip "Not safe to enable signal handler sampling on Ruby < 3.2.5 / Ruby < 3.3.4"
        end
      end
    end

    context "Process::Waiter crash regression tests" do
      # On Ruby 2.3 to 2.6, there's a crash when accessing instance variables of the `process_waiter_thread`,
      # see https://bugs.ruby-lang.org/issues/17807 .
      #
      # In those Ruby versions, there's a very special subclass of `Thread` called `Process::Waiter` that causes VM
      # crashes whenever something tries to read its instance or thread variables. This subclass of thread only
      # shows up when the `Process.detach` API gets used.
      #
      # @ivoanjo: This affected the old profiler at some point (but never affected the new profiler), but I think
      # it's useful to keep around so that we don't regress if we decide to start reading/writing some
      # info to thread objects to implement some future feature.
      it "can sample an instance of Process::Waiter without crashing" do
        forked_process = fork { sleep }
        process_waiter_thread = Process.detach(forked_process)

        start

        all_samples = try_wait_until do
          samples = samples_from_pprof_without_gc_and_overhead(recorder.serialize!)
          samples if samples_for_thread(samples, process_waiter_thread).any?
        end

        cpu_and_wall_time_worker.stop

        sample = samples_for_thread(all_samples, process_waiter_thread).first

        expect(sample.locations.first.path).to eq "In native code"

        Process.kill("TERM", forked_process)
        process_waiter_thread.join
      end
    end

    context "when the _native_sampling_loop terminates with an exception" do
      it "calls the on_failure_proc" do
        expect(described_class).to receive(:_native_sampling_loop).and_raise(StandardError.new("Simulated error"))
        expect(Datadog.logger).to receive(:warn)
        expect(Datadog::Core::Telemetry::Logger).to receive(:report)

        proc_called = Queue.new

        cpu_and_wall_time_worker.start(on_failure_proc: proc { proc_called << true })

        proc_called.pop
      end
    end
  end

  describe "Ractor safety" do
    before do
      skip "Behavior does not apply to current Ruby version" if RUBY_VERSION < "3."

      # See native_extension_spec.rb for more details on the issues we saw on 3.0
      skip "Ruby 3.0 Ractors are too buggy to run this spec" if RUBY_VERSION.start_with?("3.0.")
    end

    shared_examples_for "does not trigger a sample" do |run_ractor|
      it "does not trigger a sample" do
        cpu_and_wall_time_worker.start
        wait_until_running

        run_ractor.call

        cpu_and_wall_time_worker.stop

        samples_from_ractor =
          samples_from_pprof(recorder.serialize!)
            .select { |it| it.labels[:"thread name"] == "background ractor" }

        expect(samples_from_ractor).to be_empty
      end
    end

    context "when called from a background ractor", ractors: true do
      # Even though we're not testing it explicitly, the GC profiling hooks can sometimes be called when running these
      # specs. Unfortunately, there's a VM crash in that case as well -- https://bugs.ruby-lang.org/issues/18464 --
      # so this must be disabled when interacting with Ractors.
      let(:gc_profiling_enabled) { false }
      # ...same thing for the tracepoint for allocation counting/profiling :(
      let(:allocation_profiling_enabled) { false }

      describe "handle_sampling_signal" do
        include_examples "does not trigger a sample",
          (
            proc do
              Ractor.new do
                Thread.current.name = "background ractor"
                Datadog::Profiling::Collectors::CpuAndWallTimeWorker::Testing._native_simulate_handle_sampling_signal
              end.take
            end
          )
      end

      describe "sample_from_postponed_job" do
        include_examples "does not trigger a sample",
          (
            proc do
              Ractor.new do
                Thread.current.name = "background ractor"
                Datadog::Profiling::Collectors::CpuAndWallTimeWorker::Testing._native_simulate_sample_from_postponed_job
              end.take
            end
          )
      end

      # @ivoanjo: I initially tried to also test the GC callbacks, but it gets a bit hacky to force the thread
      # context creation for the ractors, and then simulate a GC. (For instance -- how to prevent against the context
      # creation running in parallel with a regular sample?)
    end
  end

  describe "#stop" do
    subject(:stop) { cpu_and_wall_time_worker.stop }

    context "when called immediately after start" do
      it "stops the CpuAndWallTimeWorker" do
        cpu_and_wall_time_worker.start

        stop

        expect(described_class._native_is_running?(cpu_and_wall_time_worker)).to be false
      end
    end

    context "after starting" do
      before do
        skip_if_gvl_profiling_not_supported(self) if gvl_profiling_enabled

        cpu_and_wall_time_worker.start
        wait_until_running
      end

      it "shuts down the background thread" do
        stop

        expect(Thread.list.map(&:name)).to_not include(described_class.name)
      end

      it "replaces the profiling sigprof signal handler with an empty one" do
        stop

        expect(described_class::Testing._native_current_sigprof_signal_handler).to be :empty
      end

      it "disables the garbage collection tracepoint" do
        stop

        expect(described_class::Testing._native_gc_tracepoint(cpu_and_wall_time_worker)).to_not be_enabled
      end

      it "leaves behind an empty SIGPROF signal handler" do
        stop

        # Without an empty SIGPROF signal handler (e.g. with no signal handler) the following command will make the VM
        # instantly terminate with a confusing "Profiling timer expired" message left behind. (This message doesn't
        # come from us -- it's the default message for an unhandled SIGPROF. Pretty confusing UNIX/POSIX behavior...)
        Process.kill("SIGPROF", Process.pid)
      end

      context "when GVL profiling is enabled" do
        let(:gvl_profiling_enabled) { true }

        it "disables the GVL profiling hook" do
          expect { stop }
            .to change { described_class::Testing._native_gvl_profiling_hook_active(cpu_and_wall_time_worker) }
            .from(true).to(false)
        end
      end
    end

    it "unblocks SIGPROF signal handling from the worker thread" do
      inner_ran = false

      expect(described_class).to receive(:_native_sampling_loop).and_wrap_original do |native, *args|
        native.call(*args)

        expect(described_class::Testing._native_is_sigprof_blocked_in_current_thread).to be false
        inner_ran = true
      end

      cpu_and_wall_time_worker.start
      wait_until_running

      stop

      expect(inner_ran).to be true
    end
  end

  describe "#reset_after_fork" do
    subject(:reset_after_fork) { cpu_and_wall_time_worker.reset_after_fork }

    let(:thread_context_collector) { build_thread_context_collector(recorder) }
    let(:options) { {thread_context_collector: thread_context_collector} }

    before do
      skip_if_gvl_profiling_not_supported(self) if gvl_profiling_enabled

      # This is important -- the real #reset_after_fork must not be called concurrently with the worker running,
      # which we do in this spec to make it easier to test the reset_after_fork behavior
      allow(thread_context_collector).to receive(:reset_after_fork)

      cpu_and_wall_time_worker.start
      wait_until_running
    end

    after do
      cpu_and_wall_time_worker.stop
    end

    it "disables the gc_tracepoint" do
      expect { reset_after_fork }
        .to change { described_class::Testing._native_gc_tracepoint(cpu_and_wall_time_worker).enabled? }
        .from(true).to(false)
    end

    context "when gvl_profiling_enabled is true" do
      let(:gvl_profiling_enabled) { true }

      it "disables the gvl profiling hook" do
        expect { reset_after_fork }
          .to change { described_class::Testing._native_gvl_profiling_hook_active(cpu_and_wall_time_worker) }
          .from(true).to(false)
      end
    end

    it "resets the CpuAndWallTime collector only after disabling the tracepoint" do
      expect(thread_context_collector).to receive(:reset_after_fork) do
        expect(described_class::Testing._native_gc_tracepoint(cpu_and_wall_time_worker)).to_not be_enabled
      end

      reset_after_fork
    end

    it "resets all stats" do
      cpu_and_wall_time_worker.stop

      reset_after_fork

      expect(cpu_and_wall_time_worker.stats).to match(
        {
          trigger_sample_attempts: 0,
          trigger_simulated_signal_delivery_attempts: 0,
          simulated_signal_delivery: 0,
          signal_handler_enqueued_sample: 0,
          signal_handler_wrong_thread: 0,
          signal_handler_prepared_sample: 0,
          interrupt_thread_attempts: 0,
          cpu_sampled: 0,
          cpu_skipped: 0,
          cpu_effective_sample_rate: nil,
          cpu_sampling_time_ns_min: nil,
          cpu_sampling_time_ns_max: nil,
          cpu_sampling_time_ns_total: nil,
          cpu_sampling_time_ns_avg: nil,
          allocation_sampled: nil,
          allocation_skipped: nil,
          allocation_effective_sample_rate: nil,
          allocation_sampling_time_ns_min: nil,
          allocation_sampling_time_ns_max: nil,
          allocation_sampling_time_ns_total: nil,
          allocation_sampling_time_ns_avg: nil,
          allocation_sampler_snapshot: nil,
          allocations_during_sample: nil,
          after_gvl_running: 0,
          gvl_dont_sample: 0,
          gvl_sampling_time_ns_min: nil,
          gvl_sampling_time_ns_max: nil,
          gvl_sampling_time_ns_total: nil,
          gvl_sampling_time_ns_avg: nil,
        }
      )
    end
  end

  describe "._native_allocation_count" do
    subject(:_native_allocation_count) { described_class._native_allocation_count }

    context "when CpuAndWallTimeWorker has not been started" do
      it { is_expected.to be nil }
    end

    context "when CpuAndWallTimeWorker has been started" do
      before do
        cpu_and_wall_time_worker.start
        wait_until_running
      end

      after do
        cpu_and_wall_time_worker.stop
      end

      context "when allocation profiling and allocation counting is enabled" do
        let(:allocation_profiling_enabled) { true }
        let(:allocation_counting_enabled) { true }

        it "always returns a >= 0 value" do
          expect(described_class._native_allocation_count).to be >= 0
        end

        it "returns the exact number of allocations between two calls of the method" do
          # In rare situations (once every few thousand runs) we've witnessed this test failing with
          # more than 100 allocations being reported. With some extra debugging logs and callstack
          # dumps we've tracked the extra allocations to the calling of finalizers with complex
          # arguments (e.g. *rest args) which lead to the allocation of a temporary array.
          #
          # Finalizer usage isn't really a common thing in the Ruby stdlib. In fact, there are just
          # two places where we see them being used:
          # * Weakmaps - Not used by anything in this test suite and the actual finalizer function
          #              looks simple enough, receiving a single objid.
          # * Tempfiles - Used indirectly in some of tests in this suite through `expect_in_fork`.
          #               The finalizer functions are declared as `run(*args)` which would trigger
          #               the complex calling logic.
          #
          # Thus, in a test execution where those (or any other tests using Tempfiles) run first,
          # there's a small chance that a GC gets triggered in between the two
          # `_native_allocation_count` calls and contributes with unexpected Array allocations to
          # the allocation count. To prevent this, we'll explicitly disable GC around these checks.

          GC.disable
          # To get the exact expected number of allocations, we run through the ropes once so
          # Ruby can create and cache all it needs to and hopefully flush any pending finalizer
          # executions that could affect our expectations
          described_class._native_allocation_count
          new_object = proc { Object.new }
          1.times(&new_object)
          described_class._native_allocation_count

          # Here we do the actual work we care about
          before_allocations = described_class._native_allocation_count
          100.times(&new_object)
          after_allocations = described_class._native_allocation_count

          expect(after_allocations - before_allocations).to be 100
        ensure
          GC.enable
        end

        it "returns different numbers of allocations for different threads" do
          # GC disabled for the same reason as "returns the exact number of allocations between two calls of the method"
          # spec above.
          GC.disable

          # To get the exact expected number of allocations, we run this once before so that Ruby can create and cache all
          # it needs to
          new_object = proc { Object.new }
          1.times(&new_object)

          t1_can_run = Queue.new
          t1_has_run = Queue.new
          before_t1 = nil
          after_t1 = nil

          background_t1 = Thread.new do
            before_t1 = described_class._native_allocation_count
            t1_can_run.pop

            100.times(&new_object)
            after_t1 = described_class._native_allocation_count
            t1_has_run << true
          end

          before_allocations = described_class._native_allocation_count
          t1_can_run << true
          t1_has_run.pop
          after_allocations = described_class._native_allocation_count

          background_t1.join

          # This test checks that even though we observed 100 allocations in a background thread t1, the counters for
          # the current thread were not affected by this change

          expect(after_t1 - before_t1).to be >= 100
          expect(after_allocations - before_allocations).to be < 10
        ensure
          GC.enable
        end

        context "when allocation profiling is enabled but allocation counting is disabled" do
          let(:allocation_counting_enabled) { false }

          it "always returns a nil value" do
            100.times { Object.new }

            expect(described_class._native_allocation_count).to be nil
          end
        end
      end

      context "when allocation profiling is disabled" do
        let(:allocation_profiling_enabled) { false }

        it "always returns a nil value" do
          100.times { Object.new }

          expect(described_class._native_allocation_count).to be nil
        end
      end
    end
  end

  describe "#stats_reset_not_thread_safe" do
    let(:allocation_profiling_enabled) { true }

    it "returns accumulated stats and resets them back to 0" do
      cpu_and_wall_time_worker.start
      wait_until_running

      try_wait_until do
        # Wait until we get CPU/Wall time samples. Since we have allocation
        # profiling enabled, not adding the extra reject could lead us to
        # prematurely stop waiting as soon as we get an allocation sample
        # which would result in us reaching our expectation with cpu_sampled = 0
        samples = samples_from_pprof_without_gc_and_overhead(recorder.serialize!)
          .reject { |sample| sample.values[:"alloc-samples"] > 0 }
        samples if samples.any?
      end

      stub_const("CpuAndWallTimeWorkerSpec::TestStruct", Struct.new(:foo))
      1000.times { CpuAndWallTimeWorkerSpec::TestStruct.new }

      cpu_and_wall_time_worker.stop

      stats = cpu_and_wall_time_worker.stats_and_reset_not_thread_safe

      expect(stats).to match(
        hash_including(
          cpu_sampled: be > 0,
          allocation_sampled: be > 0,
          cpu_sampling_time_ns_avg: be > 0,
          allocation_sampling_time_ns_avg: be > 0,
        )
      )

      stats = cpu_and_wall_time_worker.stats

      expect(stats).to match(
        hash_including(
          cpu_sampled: 0,
          allocation_sampled: 0,
          cpu_sampling_time_ns_avg: nil,
          allocation_sampling_time_ns_avg: nil,
        )
      )
    end
  end

  describe ".delayed_error" do
    before { allow(Datadog.logger).to receive(:warn) }

    it "on allocation, raises on start" do
      worker = described_class.allocate
      # Simulate a delayed failure pre-initialization (i.e. during new)
      Datadog::Profiling::Collectors::CpuAndWallTimeWorker::Testing._native_delayed_error(
        worker,
        "test failure"
      )

      worker.send(:initialize, **worker_settings, **options)

      proc_called = Queue.new

      # Start the worker
      worker.start(on_failure_proc: proc { proc_called << true })

      # We expect this to have been filled by the on_failure_proc
      proc_called.pop

      # And we expect the worker to be shutdown with a failure exception
      expect(described_class._native_is_running?(worker)).to be false
      exception = try_wait_until(backoff: 0.01) { worker.send(:failure_exception) }
      expect(exception.message).to include "test failure"

      worker.stop
    end

    it "raises on next iteration" do
      proc_called = Queue.new

      cpu_and_wall_time_worker.start(on_failure_proc: proc { proc_called << true })
      wait_until_running

      # Make sure things are fully running by waiting for some samples
      try_wait_until do
        samples = samples_from_pprof_without_gc_and_overhead(recorder.serialize!)
        samples if samples.any?
      end

      # Simulate a delayed failure while running
      Datadog::Profiling::Collectors::CpuAndWallTimeWorker::Testing._native_delayed_error(
        cpu_and_wall_time_worker,
        "test failure"
      )

      # We expect this to have been filled by the on_failure_proc
      proc_called.pop

      # And we expect the worker to be shutdown with a failure exception
      expect(described_class._native_is_running?(cpu_and_wall_time_worker)).to be false
      exception = try_wait_until(backoff: 0.01) { cpu_and_wall_time_worker.send(:failure_exception) }
      expect(exception.message).to include "test failure"

      cpu_and_wall_time_worker.stop
    end
  end

  describe "#wait_until_running" do
    context "when the worker starts" do
      it do
        cpu_and_wall_time_worker.start

        expect(cpu_and_wall_time_worker.wait_until_running).to be true

        cpu_and_wall_time_worker.stop
      end
    end

    context "when worker doesn't start on time" do
      it "raises an exception" do
        expect { cpu_and_wall_time_worker.wait_until_running(timeout_seconds: 0) }.to raise_error(/Timeout waiting/)
      end
    end
  end

  describe "._native_hold_signals and _native_resume_signals" do
    it "blocks/unblocks interruptions for the current thread" do
      expect(described_class::Testing._native_is_sigprof_blocked_in_current_thread).to be false

      described_class._native_hold_signals

      expect(described_class::Testing._native_is_sigprof_blocked_in_current_thread).to be true

      described_class._native_resume_signals

      expect(described_class::Testing._native_is_sigprof_blocked_in_current_thread).to be false
    end
  end

  def wait_until_running
    cpu_and_wall_time_worker.wait_until_running
  end

  # This is useful because in a bunch of tests above we want to assert on properties of the samples, and having GC
  # and profiler overhead samples is a source of randomness which causes flakiness in the assertions.
  #
  # We have separate specs that assert on these behaviors.
  def samples_from_pprof_without_gc_and_overhead(encoded_profile)
    samples_from_pprof(encoded_profile)
      .reject { |it| it.locations&.first&.path == "Garbage Collection" }
      .reject { |it| it.labels.include?(:"profiler overhead") }
  end

  def build_another_instance
    described_class.new(**worker_settings)
  end

  def build_thread_context_collector(recorder, **options)
    Datadog::Profiling::Collectors::ThreadContext.for_testing(
      recorder: recorder,
      endpoint_collection_enabled: endpoint_collection_enabled,
      timeline_enabled: timeline_enabled,
      **options,
    )
  end

  def loop_until(timeout_seconds: 5)
    deadline = Time.now + timeout_seconds

    while Time.now < deadline
      result = yield
      return result if result
    end

    raise("Wait time exhausted!")
  end
end
