# Port of c/enc/fast_log.{c,h}, find_match_length.h, utf8_util.{c,h}.
# Upstream: 42a2ed4. (literal_cost.c joins here in phase E6.)

module Brotli
  module Enc
    # fast_log.h: Log2FloorNonZero — exact, no table needed.
    def self.log2_floor_non_zero(n : Int) : Int32
      n.bit_length - 1
    end

    # kBrotliLog2Table: log2(i) for 0..255 (log2(0) := 0).
    LOG2_TABLE = begin
      table = Array(Float64).new(256, 0.0)
      (1...256).each do |i|
        table[i] = Math.log2(i.to_f64)
      end
      table
    end

    # fast_log.h: FastLog2 — log2(int), log2(0) == 0.
    def self.fast_log2(v : Int) : Float64
      return LOG2_TABLE.unsafe_fetch(v) if v < 256
      Math.log2(v.to_f64)
    end

    # find_match_length.h: length of the common prefix of
    # data[s1, limit] and data[s2, limit] (both indices into the same
    # buffer, as in C; s2 may point into the ring-buffer tail mirror).
    def self.find_match_length_with_limit(data : Bytes, s1 : Int32,
                                          s2 : Int32, limit : Int32) : Int32
      base = s1
      l = limit
      while l >= 8
        p1 = (data.to_unsafe + s1).as(Pointer(UInt64)).value
        p2 = (data.to_unsafe + s2).as(Pointer(UInt64)).value
        x = p1 ^ p2
        if x != 0
          return (s1 &- base) &+ (x.trailing_zeros_count >> 3)
        end
        s1 &+= 8
        s2 &+= 8
        l &-= 8
      end
      while l > 0 && data.unsafe_fetch(s1) == data.unsafe_fetch(s2)
        l &-= 1
        s1 &+= 1
        s2 &+= 1
      end
      s1 &- base
    end

    # utf8_util.c: BrotliParseAsUTF8 — returns {symbol, bytes_read}.
    # 0x110000 | byte marks invalid UTF-8. Reads up to 4 bytes at pos; the
    # caller must ensure the ring buffer has readable bytes there.
    private def self.parse_as_utf8(data : Bytes, pos : Int32,
                                   size : Int32) : {Int32, Int32}
      c0 = data.unsafe_fetch(pos).to_i32
      # ASCII
      if (c0 & 0x80) == 0
        return {c0, 1} if c0 > 0
      end
      # 2-byte UTF8
      if size > 1 && (c0 & 0xE0) == 0xC0 &&
         (data.unsafe_fetch(pos &+ 1) & 0xC0) == 0x80
        symbol = ((c0 & 0x1F) << 6) | (data.unsafe_fetch(pos &+ 1) & 0x3F)
        return {symbol, 2} if symbol > 0x7F
      end
      # 3-byte UTF8
      if size > 2 && (c0 & 0xF0) == 0xE0 &&
         (data.unsafe_fetch(pos &+ 1) & 0xC0) == 0x80 &&
         (data.unsafe_fetch(pos &+ 2) & 0xC0) == 0x80
        symbol = ((c0 & 0x0F) << 12) | ((data.unsafe_fetch(pos &+ 1) & 0x3F) << 6) |
                 (data.unsafe_fetch(pos &+ 2) & 0x3F)
        return {symbol, 3} if symbol > 0x7FF
      end
      # 4-byte UTF8
      if size > 3 && (c0 & 0xF8) == 0xF0 &&
         (data.unsafe_fetch(pos &+ 1) & 0xC0) == 0x80 &&
         (data.unsafe_fetch(pos &+ 2) & 0xC0) == 0x80 &&
         (data.unsafe_fetch(pos &+ 3) & 0xC0) == 0x80
        symbol = ((c0 & 0x07) << 18) | ((data.unsafe_fetch(pos &+ 1) & 0x3F) << 12) |
                 ((data.unsafe_fetch(pos &+ 2) & 0x3F) << 6) |
                 (data.unsafe_fetch(pos &+ 3) & 0x3F)
        return {symbol, 4} if symbol > 0xFFFF && symbol <= 0x10FFFF
      end
      # Not UTF8, emit a special symbol above the UTF-8 code space.
      {0x110000 | c0, 1}
    end

    # utf8_util.c: true if more than min_fraction of data[pos, pos+length]
    # (ring-buffer addressing with mask) is valid UTF-8.
    def self.mostly_utf8?(data : Bytes, pos : Int32, mask : Int32,
                          length : Int32, min_fraction : Float64) : Bool
      size_utf8 = 0
      i = 0
      while i < length
        symbol, bytes_read = parse_as_utf8(data, (pos &+ i) & mask, length &- i)
        i &+= bytes_read
        size_utf8 &+= bytes_read if symbol < 0x110000
      end
      size_utf8.to_f64 > min_fraction * length.to_f64
    end
  end
end
