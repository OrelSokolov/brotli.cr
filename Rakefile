SRC = "bin/brotli_decode"
OUT = "build/brotli_decode"
OUT_DEV = "build/brotli_decode_dev"
OUT_O3 = "build/brotli_decode_o3"

task default: :build

desc "Build the brotli_decode CLI (release mode)"
task :build do
  mkdir_p File.dirname(OUT)
  sh "crystal build --release -o #{OUT} #{SRC}"
end

namespace :build do
  desc "Build the brotli_decode CLI (dev mode, no --release)"
  task :dev do
    mkdir_p File.dirname(OUT_DEV)
    sh "crystal build -o #{OUT_DEV} #{SRC}"
  end

  # Optimized iteration (the egui.cr lesson): -O3 optimizes per unit, so
  # the object cache stays alive across src/ edits and rebuilds are quick,
  # while runtime is only ~2-3x slower than --release. Unlike --release,
  # whose single-module LLVM opt pass invalidates the cache each time.
  desc "Build the brotli_decode CLI (optimized iteration, -O3 without --release)"
  task :o3 do
    mkdir_p File.dirname(OUT_O3)
    sh "crystal build -O3 -o #{OUT_O3} #{SRC}"
  end
end

desc "Remove build artifacts"
task :clean do
  rm_rf "build"
end
