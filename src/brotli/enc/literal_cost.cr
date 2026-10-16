# Port of c/enc/literal_cost.c — literal cost model used by zopflification.
# Upstream: 42a2ed4.

module Brotli
  module Enc
    K_MIN_UTF8_RATIO = 0.75

    # literal_cost.c:20
    private def self.utf8_position(last : Int32, c : Int32,
                                   clamp : Int32) : Int32
      if c < 128
        0 # Next one is the 'Byte 1' again.
      elsif c >= 192
        Math.min(1, clamp) # Next one is the 'Byte 2' of utf-8 encoding.
      elsif last < 0xE0
        0 # Completed two or three byte coding.
      else
        Math.min(2, clamp) # Next one is the 'Byte 3' of utf-8 encoding.
      end
    end

    # literal_cost.c:35
    private def self.decide_multi_byte_stats_level(pos : Int32, len : Int32,
                                                   mask : Int32,
                                                   data : Bytes) : Int32
      counts = StaticArray(UInt32, 3).new(0_u32)
      max_utf8 = 1 # should be 2, but 1 compresses better.
      last_c = 0
      i = 0
      while i < len
        c = data.unsafe_fetch((pos &+ i) & mask)
        counts[utf8_position(last_c, c, 2)] &+= 1
        last_c = c
        i += 1
      end
      max_utf8 = 1 if counts[2] < 500
      max_utf8 = 0 if counts[1] &+ counts[2] < 25
      max_utf8
    end

    # literal_cost.c:55
    private def self.estimate_bit_costs_for_literals_utf8(
        pos : Int32, len : Int32, mask : Int32, data : Bytes,
        histogram : Slice(UInt32), cost : Slice(Float32)) : Nil
      # max_utf8 is 0 (normal ASCII single byte modeling),
      # 1 (for 2-byte UTF-8 modeling), or 2 (for 3-byte UTF-8 modeling).
      max_utf8 = decide_multi_byte_stats_level(pos, len, mask, data)
      window_half = 495
      in_window = Math.min(window_half, len)
      in_window_utf8 = StaticArray(UInt32, 3).new(0_u32)
      histogram[0, 3 * 256].fill(0)

      # Bootstrap histograms.
      last_c = 0
      utf8_pos = 0
      i = 0
      while i < in_window
        c = data.unsafe_fetch((pos &+ i) & mask)
        histogram[256 &* utf8_pos &+ c] &+= 1
        in_window_utf8[utf8_pos] &+= 1
        utf8_pos = utf8_position(last_c, c, max_utf8)
        last_c = c
        i += 1
      end

      # Compute bit costs with sliding window.
      i = 0
      while i < len
        if i >= window_half
          # Remove a byte in the past.
          c = i < window_half + 1 ? 0 : data.unsafe_fetch(
            (pos &+ i &- window_half &- 1) & mask)
          last_c2 = i < window_half + 2 ? 0 : data.unsafe_fetch(
            (pos &+ i &- window_half &- 2) & mask)
          utf8_pos2 = utf8_position(last_c2, c, max_utf8)
          histogram[256 &* utf8_pos2 &+
                    data.unsafe_fetch((pos &+ i &- window_half) & mask)] &-= 1
          in_window_utf8[utf8_pos2] &-= 1
        end
        if i &+ window_half < len
          # Add a byte in the future.
          c = data.unsafe_fetch((pos &+ i &+ window_half &- 1) & mask)
          last_c2 = data.unsafe_fetch((pos &+ i &+ window_half &- 2) & mask)
          utf8_pos2 = utf8_position(last_c2, c, max_utf8)
          histogram[256 &* utf8_pos2 &+
                    data.unsafe_fetch((pos &+ i &+ window_half) & mask)] &+= 1
          in_window_utf8[utf8_pos2] &+= 1
        end
        c = i < 1 ? 0 : data.unsafe_fetch((pos &+ i &- 1) & mask)
        last_c2 = i < 2 ? 0 : data.unsafe_fetch((pos &+ i &- 2) & mask)
        utf8_pos = utf8_position(last_c2, c, max_utf8)
        masked_pos = (pos &+ i) & mask
        histo = histogram.unsafe_fetch(256 &* utf8_pos &+
                                       data.unsafe_fetch(masked_pos))
        prologue_length = 2000
        multiplier = 0.35 / 2000
        histo = 1 if histo == 0
        lit_cost = fast_log2(in_window_utf8[utf8_pos]) - fast_log2(histo)
        lit_cost += 0.02905
        if lit_cost < 1.0
          lit_cost *= 0.5
          lit_cost += 0.5
        end
        # Make the first bytes more expensive -- seems to help, not sure why.
        if i < prologue_length
          lit_cost += 0.35 + multiplier * i
        end
        cost[i] = lit_cost.to_f32!
        i += 1
      end
    end

    # literal_cost.c:129
    def self.estimate_bit_costs_for_literals(pos : Int32, len : Int32,
                                             mask : Int32, data : Bytes,
                                             histogram : Slice(UInt32),
                                             cost : Slice(Float32)) : Nil
      if mostly_utf8?(data, pos, mask, len, K_MIN_UTF8_RATIO)
        estimate_bit_costs_for_literals_utf8(pos, len, mask, data,
                                             histogram, cost)
      else
        window_half = 2000
        in_window = Math.min(window_half, len)
        histogram[0, 256].fill(0)

        # Bootstrap histogram.
        i = 0
        while i < in_window
          histogram[data.unsafe_fetch((pos &+ i) & mask)] &+= 1
          i += 1
        end

        # Compute bit costs with sliding window.
        i = 0
        while i < len
          if i >= window_half
            # Remove a byte in the past.
            histogram[data.unsafe_fetch((pos &+ i &- window_half) & mask)] &-= 1
            in_window -= 1
          end
          if i &+ window_half < len
            # Add a byte in the future.
            histogram[data.unsafe_fetch(
              (pos &+ i &+ window_half) & mask)] &+= 1
            in_window += 1
          end
          histo = histogram.unsafe_fetch(data.unsafe_fetch((pos &+ i) & mask))
          histo = 1 if histo == 0
          lit_cost = fast_log2(in_window) - fast_log2(histo)
          lit_cost += 0.029
          if lit_cost < 1.0
            lit_cost *= 0.5
            lit_cost += 0.5
          end
          cost[i] = lit_cost.to_f32!
          i += 1
        end
      end
    end
  end
end
