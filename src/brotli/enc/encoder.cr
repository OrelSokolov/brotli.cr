# Port of c/enc/encode.c (one-shot API) + state.h subset for the fast
# fragment path. Streaming (CompressStream) is out of scope for now.
# Upstream: 42a2ed4.

module Brotli
  module Enc
    # encode.c:200 — EncodeWindowBits (large_window always false).
    # Returns {last_bytes, last_bytes_bits} seed for the bit stream.
    def self.encode_window_bits(lgwin : Int32) : {UInt16, UInt8}
      if lgwin == 16
        {0_u16, 1_u8}
      elsif lgwin == 17
        {1_u16, 7_u8}
      elsif lgwin > 17
        {(((lgwin - 17) << 1) | 0x01).to_u16!, 4_u8}
      else
        {(((lgwin - 8) << 4) | 0x01).to_u16!, 7_u8}
      end
    end

    # One-shot encoder: Brotli.encode(data, quality, lgwin).
    class Encoder
      property params : Params

      def initialize(@params : Params = Params.new)
      end

      def initialize(quality : Int32, lgwin : Int32 = 22,
                     mode : Mode = Mode::Generic)
        @params = Params.new(quality, lgwin)
        @params.mode = mode
      end

      def encode(input : Bytes) : Bytes
        Enc.sanitize_params!(@params)
        @params.lgblock = Enc.compute_lg_block(@params)
        choose_distance_params
        case @params.quality
        when FAST_ONE_PASS_COMPRESSION_QUALITY
          encode_one_pass(input)
        else
          raise NotImplementedError.new(
            "quality #{@params.quality} is not ported yet (phases E3+)")
        end
      end

      # encode.c:626 — ChooseDistanceParams (mode FONT and user overrides
      # only apply at q >= 4; the fast path is always npostfix=0, ndirect=0).
      private def choose_distance_params : Nil
        npostfix = 0_u32
        ndirect = 0_u32
        if @params.quality >= MIN_QUALITY_FOR_NONZERO_DISTANCE_PARAMS
          if @params.mode == Mode::Font
            npostfix = 1_u32
            ndirect = 12_u32
          end
          ndirect_msb = (ndirect >> npostfix) & 0x0F
          if npostfix > Brotli::MAX_NPOSTFIX || ndirect > Brotli::MAX_NDIRECT ||
             ((ndirect_msb << npostfix) != ndirect)
            npostfix = 0_u32
            ndirect = 0_u32
          end
        end
        Enc.init_distance_params(@params.dist, npostfix, ndirect)
      end

      # encode.c:1437 — the q0/q1 fast loop, one-shot: chunks the input by
      # 1 << lgwin fragments, carrying last_bytes between fragments.
      private def encode_one_pass(input : Bytes) : Bytes
        lgwin = @params.lgwin
        if lgwin < 18
          lgwin = 18 # C: fast qualities need the 2^18 window
        end

        # encode.c:157 — HashTableSize + q0 odd-shift fixup.
        max_table_size = Enc.max_hash_table_size(@params.quality).to_u64
        htsize = 256_u64
        while htsize < max_table_size && htsize < input.size
          htsize <<= 1
        end
        if (htsize & 0xAAAAA) == 0 # only odd shifts for one-pass
          htsize <<= 1
        end

        last_bytes, last_bytes_bits = Enc.encode_window_bits(lgwin)
        arena = OnePassArena.new
        table = Slice(Int32).new(htsize.to_i32)
        out = IO::Memory.new(input.size // 2 + 64)
        block_size_limit = 1_u64 << lgwin

        pos = 0
        loop do
          remaining = input.size - pos
          block = Math.min(remaining.to_u64, block_size_limit).to_i32
          is_last = remaining == block

          storage = Bytes.new(2 &* block &+ 503)
          storage[0] = (last_bytes & 0xFF).to_u8!
          storage[1] = (last_bytes >> 8).to_u8!
          w = BitWriter.new(storage, last_bytes_bits.to_i32)
          table.fill(0)

          Enc.compress_fragment_fast(arena, input, pos, block, is_last,
                                     table, htsize.to_i32, w)

          out_bytes = w.pos >> 3
          out.write(storage[0, out_bytes])
          last_bytes = storage.unsafe_fetch(out_bytes).to_u16
          last_bytes_bits = (w.pos & 7).to_u8!
          break if is_last
          pos += block
        end
        out.to_slice
      end
    end
  end

  # One-shot convenience API.
  def self.encode(input : Bytes, quality : Int32 = 11, lgwin : Int32 = 22,
                  mode = Enc::Mode::Generic) : Bytes
    Enc::Encoder.new(quality, lgwin, mode).encode(input)
  end
end
