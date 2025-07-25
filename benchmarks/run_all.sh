#!/bin/sh

# This script is invoked by benchmarking-platform shell scripts
# to run all of the benchmarks defined in the tracer.

set -ex

for file in \
  `dirname "$0"`/error_tracking_simple.rb \
  `dirname "$0"`/di_instrument.rb \
  `dirname "$0"`/library_gem_loading.rb \
  `dirname "$0"`/profiling_allocation.rb \
  `dirname "$0"`/profiling_gc.rb \
  `dirname "$0"`/profiling_hold_resume_interruptions.rb \
  `dirname "$0"`/profiling_http_transport.rb \
  `dirname "$0"`/profiling_memory_sample_serialize.rb \
  `dirname "$0"`/profiling_sample_loop_v2.rb \
  `dirname "$0"`/profiling_sample_serialize.rb \
  `dirname "$0"`/profiling_sample_gvl.rb \
  `dirname "$0"`/profiling_string_storage_intern.rb \
  `dirname "$0"`/tracing_trace.rb;
do
  bundle exec ruby "$file"
done
