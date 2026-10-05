# Mutation differential test (PLAN.md phase 5): bit-flips and truncations
# of corpus files must produce the same result AND error code as the C
# oracle (tmp_c/brotli_oracle).
#
# Usage: crystal run --release tools/mutation_test.cr -- [corpus-dir] [iters]
#   corpus-dir default: upstream/brotli/tests/testdata
#   iters (mutations per file) default: 40

require "../src/brotli"

dir = ARGV[0]? || "upstream/brotli/tests/testdata"
iters = (ARGV[1]? || "40").to_i
oracle = "tmp_c/brotli_oracle"
tmp = File.tempname("brotli_mut")
at_exit { File.delete?(tmp) }

# Base corpus files (skip the .00..NN truncation variants).
files = Dir["#{dir}/*.compressed"].sort
puts "mutating #{files.size} files x #{iters} mutations"

def run_oracle(oracle, path)
  out_path = path + ".out"
  error_io = IO::Memory.new
  res = Process.run(oracle, [path, out_path], error: error_io)
  err = error_io.to_s
  output = File.exists?(out_path) ? File.read(out_path) : ""
  File.delete?(out_path)
  code = 0
  if m = /ERROR code=(-?\d+)/.match(err)
    code = m[1].to_i
  end
  {res.exit_code || 0, code, output}
end

def run_mine(bytes)
  begin
    {0, 0, Brotli::Decoder.new.decode(bytes)}
  rescue e : Brotli::DecodeError
    if e.code == Brotli::DECODER_NEEDS_MORE_INPUT
      {2, 2, ""}
    else
      {1, e.code, ""}
    end
  end
end

rng = Random.new(20261004)
pass = 0
fail = 0
files.each do |f|
  orig = File.read(f).to_slice
  (iters + 1).times do |it|
    # iteration 0: unmutated sanity check
    if it == 0
      mutated = orig.dup
    else
      mutated = orig.dup
      case rng.rand(3)
      when 0 # single bit flip
        pos = rng.rand(mutated.size)
        bit = rng.rand(8)
        mutated[pos] ^= (1 << bit).to_u8
      when 1 # byte smash
        pos = rng.rand(mutated.size)
        mutated[pos] = rng.rand(256).to_u8
      else # truncation
        mutated = mutated[0, rng.rand(mutated.size + 1)]
      end
    end
    File.write(tmp, mutated)

    oe, oc, ob = run_oracle(oracle, tmp)
    me, mc, mb = run_mine(mutated)

    ok = oe == me && (oe != 0 || ob.to_slice == mb) && (oe != 1 || oc == mc)
    if ok
      pass += 1
    else
      fail += 1
      puts "FAIL #{File.basename(f)} it=#{it} size=#{mutated.size}: " \
           "oracle exit=#{oe} code=#{oc} (#{ob.bytesize}B) vs " \
           "mine exit=#{me} code=#{mc} (#{mb.bytesize}B)"
    end
  end
end
puts "----------------------------------------"
puts "pass=#{pass} fail=#{fail}"
exit(fail == 0 ? 0 : 1)
