# Port of c/enc/write_bits.h (+ UpdateBits/RewindBitPosition from
# compress_fragment.c, they live with the bit writer). Upstream: 42a2ed4.

module Brotli
  module Enc
    # Writes bits into bytes in increasing addresses, within a byte
    # least-significant-bit first (RFC 7932 bit order).
    #
    # Contract (same as C):
    #   * up to 56 bits per call; (bits >> n_bits) must be 0;
    #   * the byte at the NEW pos >> 3 must already be zero (the caller
    #     zeroes it via prepare_storage or by seeding from last_bytes).
    class BitWriter
      property storage : Bytes
      property pos : Int32 # storage_ix, bit offset

      def initialize(@storage : Bytes, @pos : Int32 = 0)
      end

      # n_bits is coerced (depths arrive as UInt8/UInt32 lookups);
      # bits values are zero-extended from any integer width.
      def write_bits(n_bits : Int, bits : UInt64) : Nil
        n = n_bits.to_i32
        byte = @pos >> 3
        v = @storage.unsafe_fetch(byte).to_u64 | (bits << (@pos & 7))
        (@storage.to_unsafe + byte).as(Pointer(UInt64)).value = v
        @pos &+= n
      end

      def write_bits(n_bits : Int, bits : Int) : Nil
        write_bits(n_bits, bits.to_u64!)
      end

      # array[pos >> 3] = 0; call before writing at a byte-aligned position.
      def prepare_storage(pos : Int32) : Nil
        @storage[pos >> 3] = 0
      end

      # Overwrites n_bits at an arbitrary earlier bit position (compress_fragment.c:
      # in-place MLEN patch of an already-written metablock header). Does not
      # move #pos. (bits >> n_bits) must be 0.
      def update_bits(n_bits : Int32, bits : UInt32, pos : Int32) : Nil
        remaining_bits = bits
        while n_bits > 0
          byte_pos = pos >> 3
          n_unchanged_bits = pos & 7
          n_changed_bits = Math.min(n_bits, 8 - n_unchanged_bits)
          total_bits = n_unchanged_bits + n_changed_bits
          mask = (~((1_u32 << total_bits) &- 1)) | ((1_u32 << n_unchanged_bits) &- 1)
          unchanged_bits = @storage.unsafe_fetch(byte_pos).to_u32 & mask
          changed_bits = remaining_bits & ((1_u32 << n_changed_bits) &- 1)
          @storage[byte_pos] =
            ((changed_bits << n_unchanged_bits) | unchanged_bits).to_u8!
          n_bits &-= n_changed_bits
          remaining_bits >>= n_changed_bits
          pos &+= n_changed_bits
        end
      end

      # Moves #pos back; the partially-written byte is masked to its valid
      # bits so a subsequent write starts clean (compress_fragment.c:
      # uncompressed-metablock escape).
      def rewind_bit_position(new_pos : Int32) : Nil
        bitpos = new_pos & 7
        mask = ((1_u32 << bitpos) &- 1).to_u8!
        @storage[new_pos >> 3] &= mask
        @pos = new_pos
      end
    end
  end
end
