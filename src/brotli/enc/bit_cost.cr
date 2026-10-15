# Port of c/enc/bit_cost.{c,h} (grows with the q4+ pipeline in E5).
# Upstream: 42a2ed4.

module Brotli
  module Enc
    # bit_cost.c:18 — Shannon entropy estimate in bits over the histogram
    # (FastLog2-based). Note FastLog2(0) == 0, so zero counts contribute
    # nothing. Clamped from below by `sum` (at least 1 bit per symbol).
    def self.bits_entropy(population : Slice(UInt32), size : Int32) : Float64
      sum = 0_u64
      retval = 0.0
      i = 0
      while i < size
        p = population.unsafe_fetch(i)
        sum &+= p
        retval -= p.to_f64 * fast_log2(p)
        i += 1
      end
      retval += sum.to_f64 * fast_log2(sum) if sum != 0
      # At least one bit per literal is needed.
      sum_f = sum.to_f64
      retval = sum_f if retval < sum_f
      retval
    end
  end
end
