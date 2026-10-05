# Port of c/dec/bit_reader.{h,c} — 64-bit build (brotli_reg_t == UInt64,
# BROTLI_UNALIGNED_READ_FAST == 1). Upstream: 42a2ed4.
#
# Differences from C, on purpose:
#   * pointers -> indices into an @input slice; @last_in/@guard_in are
#     indices. The caller must provide >= FAST_INPUT_SLACK readable
#     bytes past the logical end of input (see src/brotli.cr) so the
#     unaligned 32/64-bit window loads never fault.
#   * BrotliFillBitWindow's specialized n_bits<=8/<=16 branches only
#     fire for compile-time-constant n in C; here n is runtime, so only
#     the general branch (load 32 bits) is ported — same semantics.
#   * out-parameter + BROTLI_BOOL pairs become nilable returns.
#
# Bit order (RFC 7932): bits are consumed LSB-first within each byte.

{% raise "brotli.cr: big-endian targets need byte-swapped loads" if flag?(:big_endian) %}

module Brotli
  struct BitReader
    # 162 bits + 7 bytes (upstream bit_reader.h).
    FAST_INPUT_SLACK = 28

    # Saved state for speculative reads (BrotliBitReaderState).
    struct Memento
      getter val, bit_pos, next_in, avail_in

      def initialize(@val : UInt64, @bit_pos : Int32,
                     @next_in : Int32, @avail_in : Int32)
      end
    end

    @val : UInt64 = 0     # pre-fetched bits
    @bit_pos : Int32 = 0  # current bit-reading position in val_
    @next_in : Int32 = 0
    @last_in : Int32 = 0  # == next_in + avail_in
    @guard_in : Int32 = 0 # index from which "fast-path" is prohibited

    def initialize(@input : Bytes, next_in : Int32 = 0, avail_in : Int32 = 0)
      set_input(next_in, avail_in)
    end

    # BrotliBitReaderSetInput
    def set_input(next_in : Int32, avail_in : Int32) : Nil
      @next_in = next_in
      @last_in = next_in + avail_in
      # Fast path is allowed while at least FAST_INPUT_SLACK bytes remain.
      if avail_in + 1 > FAST_INPUT_SLACK
        @guard_in = next_in + avail_in + 1 - FAST_INPUT_SLACK
      else
        @guard_in = next_in
      end
    end

    # BrotliInitBitReader
    def init : Nil
      @val = 0
      @bit_pos = 0
    end

    # BrotliWarmupBitReader (UNALIGNED_READ_FAST build: no alignment fixup).
    def warmup? : Bool
      if available_bits == 0
        @val = 0
        return false unless pull_byte
      end
      true
    end

    @[AlwaysInline]
    def avail_in : Int32
      @last_in - @next_in
    end

    getter next_in, last_in, guard_in

    # Switch the underlying input slice (C re-points br->next_in into
    # s->buffer for the internal streaming buffer).
    def set_input(input : Bytes, next_in : Int32, avail_in : Int32) : Nil
      @input = input
      set_input(next_in, avail_in)
    end

    def save_state : Memento
      Memento.new(@val, @bit_pos, @next_in, avail_in)
    end

    def restore_state(from : Memento) : Nil
      @val = from.val
      @bit_pos = from.bit_pos
      @next_in = from.next_in
      set_input(from.next_in, from.avail_in)
    end

    @[AlwaysInline]
    def available_bits : Int32
      @bit_pos
    end

    # BrotliGetRemainingBytes
    def remaining_bytes : Int32
      cap = 1 << 24 # BROTLI_LARGE_MAX_WBITS
      a = avail_in
      return cap if a > cap
      a + (available_bits >> 3)
    end

    # BrotliCheckInputAmount: >= FAST_INPUT_SLACK bytes left in input.
    @[AlwaysInline]
    def check_input_amount : Bool
      @next_in < @guard_in
    end

    # BrotliFillBitWindow — general branch only (see file comment).
    @[AlwaysInline]
    def fill_bit_window : Nil
      bit_pos = @bit_pos
      if bit_pos <= 32
        @val |= load32le(@next_in).to_u64 << bit_pos
        @bit_pos = bit_pos + 32
        @next_in += 4
      end
    end

    # BrotliFillBitWindow16
    @[AlwaysInline]
    def fill_bit_window16 : Nil
      fill_bit_window
    end

    # BrotliPullByte
    @[AlwaysInline]
    def pull_byte : Bool
      return false if @next_in == @last_in
      @val |= @input.unsafe_fetch(@next_in).to_u64 << @bit_pos
      @bit_pos += 8
      @next_in += 1
      true
    end

    # BrotliGetBitsUnmasked
    @[AlwaysInline]
    def get_bits_unmasked : UInt64
      @val
    end

    # BrotliGet16BitsUnmasked
    @[AlwaysInline]
    def get16_bits_unmasked : UInt64
      fill_bit_window
      @val
    end

    @[AlwaysInline]
    def self.bit_mask(n : Int32) : UInt64
      ~(~0_u64 << n)
    end

    # BrotliGetBits: peek n bits without advancing.
    @[AlwaysInline]
    def get_bits(n : Int32) : UInt64
      fill_bit_window
      @val & BitReader.bit_mask(n)
    end

    # BrotliSafeGetBits: nil if there is not enough input.
    def safe_get_bits(n : Int32) : UInt64?
      while available_bits < n
        return nil unless pull_byte
      end
      @val & BitReader.bit_mask(n)
    end

    # BrotliDropBits
    @[AlwaysInline]
    def drop_bits(n : Int32) : Nil
      @bit_pos -= n
      @val >>= n
    end

    # BrotliBitReaderNormalize: drop "spectre" bits above bit_pos.
    def normalize : Nil
      @val &= ((1_u64 << @bit_pos) - 1) if @bit_pos < 64
    end

    # BrotliBitReaderUnload: return unconsumed whole bytes to the input.
    def unload : Nil
      unused_bytes = available_bits >> 3
      @next_in -= unused_bytes if unused_bytes != 0
      @bit_pos -= unused_bytes << 3
      normalize
    end

    # BrotliTakeBits: precondition — accumulator holds >= n bits.
    @[AlwaysInline]
    def take_bits(n : Int32) : UInt64
      val = @val & BitReader.bit_mask(n)
      drop_bits(n)
      val
    end

    # BrotliReadBits24 (n <= 24; 64-bit build — single window fill).
    @[AlwaysInline]
    def read_bits24(n : Int32) : UInt64
      fill_bit_window
      take_bits(n)
    end

    # BrotliReadBits32 (n <= 32; 64-bit build).
    @[AlwaysInline]
    def read_bits32(n : Int32) : UInt64
      fill_bit_window
      take_bits(n)
    end

    # BrotliSafeReadBits (n <= 24): nil if there is not enough input.
    def safe_read_bits(n : Int32) : UInt64?
      while available_bits < n
        return nil unless pull_byte
      end
      take_bits(n)
    end

    # BrotliSafeReadBits32 (n <= 32; 64-bit build).
    def safe_read_bits32(n : Int32) : UInt64?
      safe_read_bits(n)
    end

    # BrotliJumpToByteBoundary: false if the skipped pad bits are non-zero.
    def jump_to_byte_boundary : Bool
      pad_bits_count = available_bits & 0x7
      pad_bits = 0_u64
      pad_bits = take_bits(pad_bits_count) if pad_bits_count != 0
      normalize
      pad_bits == 0
    end

    # BrotliDropBytes: precondition — accumulator is byte-empty.
    def drop_bytes(num : Int32) : Nil
      @next_in += num
    end

    # BrotliCopyBytes (num <= remaining_bytes).
    def copy_bytes(dest : Bytes, num : Int32) : Nil
      i = 0
      while available_bits >= 8 && num > 0
        dest.unsafe_put(i, @val.to_u8!)
        drop_bits(8)
        i += 1
        num -= 1
      end
      normalize
      if num > 0
        pos = @next_in
        num.times { |k| dest.unsafe_put(i + k, @input.unsafe_fetch(pos + k)) }
        drop_bytes(num)
      end
    end

    # Host is little-endian (checked at compile time above).
    @[AlwaysInline]
    private def load32le(i : Int32) : UInt32
      p = @input.to_unsafe + i
      p[0].to_u32 | (p[1].to_u32 << 8) | (p[2].to_u32 << 16) | (p[3].to_u32 << 24)
    end
  end
end
