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

    # bit_cost_inc.h:12 — BrotliPopulationCost. Estimation of the entropy
    # cost of a histogram including the cost of encoding its huffman tree
    # (code-length code histogram estimate). Shared by all histogram types.
    def self.population_cost(histogram : Histogram) : Float64
      one_symbol_histogram_cost = 12.0
      two_symbol_histogram_cost = 20.0
      three_symbol_histogram_cost = 28.0
      four_symbol_histogram_cost = 37.0
      data_size = histogram.data_size
      count = 0
      s = StaticArray(UInt32, 5).new(0_u32)
      if histogram.total_count == 0
        return one_symbol_histogram_cost
      end
      i = 0
      while i < data_size
        if histogram.data.unsafe_fetch(i) > 0
          s[count] = i.to_u32!
          count += 1
          break if count > 4
        end
        i += 1
      end
      case count
      when 1
        one_symbol_histogram_cost
      when 2
        two_symbol_histogram_cost + histogram.total_count.to_f64
      when 3
        histo0 = histogram.data.unsafe_fetch(s[0])
        histo1 = histogram.data.unsafe_fetch(s[1])
        histo2 = histogram.data.unsafe_fetch(s[2])
        histomax = Math.max(histo0, Math.max(histo1, histo2))
        three_symbol_histogram_cost +
          2.0 * (histo0 + histo1 + histo2) - histomax
      when 4
        histo = StaticArray(UInt32, 4).new(0_u32)
        4.times { |j| histo[j] = histogram.data.unsafe_fetch(s[j]) }
        # Sort (descending, as the C selection-sort with > does).
        4.times do |j|
          k = j + 1
          while k < 4
            if histo[k] > histo[j]
              histo[j], histo[k] = histo[k], histo[j]
            end
            k += 1
          end
        end
        h23 = histo[2] &+ histo[3]
        histomax = Math.max(h23, histo[0])
        four_symbol_histogram_cost +
          3.0 * h23 + 2.0 * (histo[0] + histo[1]) - histomax
      else
        # Entropy of the histogram plus a simplified code-length-code
        # histogram estimate (zero repeat code 17 only).
        max_depth = 1
        depth_histo = StaticArray(UInt32, Brotli::CODE_LENGTH_CODES).new(0_u32)
        bits = 0.0
        log2total = fast_log2(histogram.total_count)
        i = 0
        while i < data_size
          if histogram.data.unsafe_fetch(i) > 0
            log2p = log2total - fast_log2(histogram.data.unsafe_fetch(i))
            depth = (log2p + 0.5).to_i32!
            bits += histogram.data.unsafe_fetch(i).to_f64 * log2p
            depth = 15 if depth > 15
            max_depth = depth if depth > max_depth
            depth_histo[depth] &+= 1
            i += 1
          else
            reps = 1_u32
            k = i + 1
            while k < data_size && histogram.data.unsafe_fetch(k) == 0
              reps &+= 1
              k += 1
            end
            i += reps
            if i == data_size
              # Last zero run is encoded only implicitly.
              break
            end
            if reps < 3
              depth_histo[0] &+= reps
            else
              reps &-= 2
              while reps > 0
                depth_histo[Brotli::REPEAT_ZERO_CODE_LENGTH] &+= 1
                bits += 3
                reps >>= 3
              end
            end
          end
        end
        # Estimated encoding cost of the code length code histogram.
        bits += (18 + 2 * max_depth).to_f64
        # Entropy of the code length code histogram.
        depth_slice = depth_histo.to_slice
        bits += bits_entropy(depth_slice, Brotli::CODE_LENGTH_CODES)
        bits
      end
    end
  end
end
