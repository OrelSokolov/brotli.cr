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
        # encode.c:1343 — the one-shot API advertises the input size; it
        # steers ChooseHasher (q4 H54 for >= 1MiB) and context modeling.
        @params.size_hint = input.size.to_u32!
        @params.lgblock = Enc.compute_lg_block(@params)
        Enc.choose_hasher(@params, @params.hasher)
        choose_distance_params
        case @params.quality
        when FAST_ONE_PASS_COMPRESSION_QUALITY
          encode_fast(input, one_pass: true)
        when FAST_TWO_PASS_COMPRESSION_QUALITY
          encode_fast(input, one_pass: false)
        when .<(MIN_QUALITY_FOR_BLOCK_SPLIT)
          encode_blocks(input)
        when .<(MIN_QUALITY_FOR_HQ_BLOCK_SPLITTING)
          encode_metablocks(input)
        else
          encode_hq(input)
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
      private def encode_fast(input : Bytes, one_pass : Bool) : Bytes
        lgwin = @params.lgwin
        if lgwin < 18
          lgwin = 18 # C: fast qualities need the 2^18 window
        end

        # encode.c:157 — HashTableSize (+ q0 odd-shift fixup, one-pass only).
        max_table_size = Enc.max_hash_table_size(@params.quality).to_u64
        htsize = 256_u64
        while htsize < max_table_size && htsize < input.size
          htsize <<= 1
        end
        if one_pass && (htsize & 0xAAAAA) == 0 # only odd shifts for one-pass
          htsize <<= 1
        end

        last_bytes, last_bytes_bits = Enc.encode_window_bits(lgwin)
        one_pass_arena = one_pass ? OnePassArena.new : nil
        two_pass_arena = one_pass ? nil : TwoPassArena.new
        command_buf = one_pass ? nil : Slice(UInt32).new(TWO_PASS_BLOCK_SIZE)
        literal_buf = one_pass ? nil : Bytes.new(TWO_PASS_BLOCK_SIZE)
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

          if one_pass
            Enc.compress_fragment_fast(one_pass_arena.not_nil!, input, pos,
                                       block, is_last, table, htsize.to_i32, w)
          else
            Enc.compress_fragment_two_pass(
              two_pass_arena.not_nil!, input, pos, block, is_last,
              command_buf.not_nil!, literal_buf.not_nil!, table,
              htsize.to_i32, w)
          end

          out_bytes = w.pos >> 3
          out.write(storage[0, out_bytes])
          last_bytes = storage.unsafe_fetch(out_bytes).to_u16
          last_bytes_bits = (w.pos & 7).to_u8!
          break if is_last
          pos += block
        end
        out.to_slice
      end
      # encode.c:466 — ShouldCompress.
      private def should_compress?(data : Bytes, mask : Int32,
                                   last_flush_pos : Int32, bytes : Int32,
                                   num_literals : Int32,
                                   num_commands : Int32) : Bool
        return false if bytes <= 2
        if num_commands < (bytes >> 8) + 2
          if num_literals.to_f64 > 0.99 * bytes
            literal_histo = Slice(UInt32).new(256)
            sample_rate = 13
            min_entropy = 7.92
            bit_cost_threshold = bytes.to_f64 * min_entropy / sample_rate
            t = (bytes + sample_rate - 1) // sample_rate
            pos = last_flush_pos
            t.times do
              literal_histo[data.unsafe_fetch(pos & mask)] &+= 1
              pos += sample_rate
            end
            return false if Enc.bits_entropy(literal_histo, 256) >
                            bit_cost_threshold
          end
        end
        true
      end

      # The q2/q3 path (encode.c EncodeData/WriteMetaBlockInternal, one-shot
      # simplified): fragments of 1 << lgwin processed independently (fresh
      # hasher per fragment, as in the fast qualities — window never wraps,
      # so the ring buffer is the fragment padded to a power of two); inside
      # a fragment, blocks of 1 << lgblock become one metablock each
      # (fast static-entropy storage for q2, trivial for q3, uncompressed
      # fallback gated by should_compress?).
      private def encode_blocks(input : Bytes) : Bytes
        lgwin = @params.lgwin
        window = 1 << lgwin
        lgblock = @params.lgblock
        max_block = Math.min(1 << lgblock,
                             Enc.max_metablock_size(@params).to_i32)
        dict = EncoderDictionary.default

        last_bytes, last_bytes_bits = Enc.encode_window_bits(lgwin)
        out = IO::Memory.new(input.size // 2 + 64)

        # The bit stream is continuous across fragments, and so is the
        # decoder's distance ring buffer — short distance codes (0..15)
        # in later fragments reference it. Resetting per fragment would
        # desync them (C keeps s->dist_cache_ across EncodeData calls).
        # 16 entries: PrepareDistanceCache fills indices 4..15.
        dist_cache = Slice(Int32).new(Brotli::NUM_DISTANCE_SHORT_CODES)
        dist_cache[0, 4].copy_from(Slice[4, 11, 15, 16])

        frag_pos = 0
        loop do
          frag = Math.min(input.size - frag_pos, window)
          is_last_fragment = frag_pos + frag >= input.size

          # Ring buffer: the fragment padded to a power of two (mask needs
          # pow2; all positions stay below the ring end, no wrapping).
          # +16 slack: hashers read past the logical end like the C tail.
          rb_bits = Math.max(log2_ceil(frag), 1)
          rb_size = 1 << rb_bits
          rb = Bytes.new(rb_size + 16)
          rb[0, frag].copy_from(input[frag_pos, frag])
          mask = rb_size - 1

          hasher = @params.hasher.type == 3 ? QuicklyHasher.h3 :
                   QuicklyHasher.h2
          hasher.prepare(rb, true, frag)
          arena = MetablockArena.new

          storage = Bytes.new(2 &* frag &+ 503)
          storage[0] = (last_bytes & 0xFF).to_u8!
          storage[1] = (last_bytes >> 8).to_u8!
          w = BitWriter.new(storage, last_bytes_bits.to_i32)

          if frag == 0
            # Write the ISLAST and ISEMPTY bits.
            w.write_bits(2, 3)
            w.pos = (w.pos &+ 7) & ~7
          else
            pos = 0
            last_insert_len = 0
            num_literals_total = 0
            while pos < frag
              block = Math.min(max_block, frag - pos)
              is_last_block = pos + block >= frag && is_last_fragment
              saved_dist_cache = dist_cache[0, 4].dup
              commands = [] of Command
              last_insert_len, num_literals =
                Enc.create_backward_references(block, pos, frag_pos, rb, mask,
                                               @params, hasher, dict,
                                               dist_cache, last_insert_len,
                                               commands)
              num_literals_total += num_literals
              # encode.c:1181 — the pending insert run becomes a command on
              # EVERY block flush (not just the last): without it a block
              # with no copy commands would leave MLEN uncovered.
              if last_insert_len > 0
                commands << Command.insert(last_insert_len)
                num_literals_total += last_insert_len
                last_insert_len = 0
              end

              if should_compress?(rb, mask, pos, block, num_literals_total,
                                  commands.size)
                if @params.quality <= MAX_QUALITY_FOR_STATIC_ENTROPY_CODES
                  Enc.store_meta_block_fast(arena, rb, pos, block, mask,
                                            is_last_block, @params, commands, w)
                else
                  Enc.store_meta_block_trivial(arena, rb, pos, block, mask,
                                               is_last_block,
                                               @params.dist.alphabet_size_max
                                                 .to_i32,
                                               commands, w)
                end
              else
                dist_cache[0, 4].copy_from(saved_dist_cache)
                Enc.store_uncompressed_meta_block(is_last_block, rb, pos,
                                                  mask, block, w)
              end
              hasher.stitch_to_previous_block(block, pos + block, rb, mask)
              pos += block
              num_literals_total = 0
            end
            # Non-last fragments end byte-aligned by the stored metablocks;
            # if a fragment ended uncompressed non-last, no alignment is
            # needed beyond what store_uncompressed did.
          end

          out_bytes = w.pos >> 3
          out.write(storage[0, out_bytes])
          last_bytes = storage.unsafe_fetch(out_bytes).to_u16
          last_bytes_bits = (w.pos & 7).to_u8!
          break if is_last_fragment || frag == 0
          frag_pos += frag
        end
        out.to_slice
      end

      # encode.c:507 WriteMetaBlockInternal + EncodeData flush, q4..q9 route:
      # one metablock per window fragment (input blocks merge up to
      # MaxMetablockSize, which always covers a fragment for lgwin <= 22).
      # The HQ path (q10+) base64 regions and BrotliBuildMetaBlock are E6.
      private def encode_metablocks(input : Bytes) : Bytes
        lgwin = @params.lgwin
        window = 1 << lgwin
        dict = EncoderDictionary.default
        literal_context_mode = 2 # CONTEXT_UTF8 (ChooseContextMode, q < 10)

        last_bytes, last_bytes_bits = Enc.encode_window_bits(lgwin)
        out = IO::Memory.new(input.size // 2 + 64)

        # See encode_blocks: the distance cache is continuous across
        # fragments, matching the decoder's ring buffer.
        dist_cache = Slice(Int32).new(Brotli::NUM_DISTANCE_SHORT_CODES)
        dist_cache[0, 4].copy_from(Slice[4, 11, 15, 16])

        frag_pos = 0
        loop do
          frag = Math.min(input.size - frag_pos, window)
          is_last_fragment = frag_pos + frag >= input.size

          rb_bits = Math.max(log2_ceil(frag), 1)
          rb_size = 1 << rb_bits
          # +16 slack: hashers read up to 8 bytes past the logical end
          # (StoreLookahead / compare tails), like the C ring buffer tail.
          rb = Bytes.new(rb_size + 16)
          rb[0, frag].copy_from(input[frag_pos, frag])
          mask = rb_size - 1

          hasher = case @params.hasher.type
                   when 2 then QuicklyHasher.h2
                   when 3 then QuicklyHasher.h3
                   when 4 then QuicklyHasher.h4
                   when 54 then QuicklyHasher.h54
                   when 5
                     LongestMatchHasher.new(@params.hasher.bucket_bits,
                                            @params.hasher.block_bits,
                                            @params.hasher.num_last_distances_to_check,
                                            false)
                   when 6
                     LongestMatchHasher.new(@params.hasher.bucket_bits,
                                            @params.hasher.block_bits,
                                            @params.hasher.num_last_distances_to_check,
                                            true)
                   when 40 then ForgetfulChainHasher.h40(@params.quality)
                   when 41 then ForgetfulChainHasher.h41(@params.quality)
                   when 42 then ForgetfulChainHasher.h42(@params.quality)
                   else
                     raise NotImplementedError.new(
                       "hasher type #{@params.hasher.type} is not ported yet")
                   end
          hasher.prepare(rb, true, frag)
          arena = MetablockArena.new
          context_map_arena = ContextMapArena.new

          storage = Bytes.new(2 &* frag &+ 503)
          storage[0] = (last_bytes & 0xFF).to_u8!
          storage[1] = (last_bytes >> 8).to_u8!
          w = BitWriter.new(storage, last_bytes_bits.to_i32)

          if frag == 0
            # Write the ISLAST and ISEMPTY bits.
            w.write_bits(2, 3)
            w.pos = (w.pos &+ 7) & ~7
          else
            # encode.c:1118: prev bytes come from before the flush position;
            # at a fragment boundary that is the tail of the previous one.
            prev_byte = frag_pos > 0 ? input.unsafe_fetch(frag_pos - 1) : 0_u8
            prev_byte2 = frag_pos > 1 ? input.unsafe_fetch(frag_pos - 2) : 0_u8

            saved_dist_cache = dist_cache[0, 4].dup
            commands = [] of Command
            last_insert_len, num_literals =
              Enc.create_backward_references(frag, 0, frag_pos, rb, mask,
                                             @params, hasher, dict,
                                             dist_cache, 0, commands)
            # Create the last insert-only command (encode.c:1181).
            if last_insert_len > 0
              commands << Command.insert(last_insert_len)
              num_literals += last_insert_len
            end

            if should_compress?(rb, mask, 0, frag, num_literals, commands.size)
              mb = MetaBlockSplit.new
              num_literal_contexts = 1
              literal_context_map = nil
              unless @params.disable_literal_context_modeling
                nctx = Pointer(Int32).malloc(1)
                nctx.value = 1
                lmap = Pointer(Slice(UInt32)).malloc(1)
                lmap.value = Slice(UInt32).empty
                Enc.decide_over_literal_context_modeling(
                  rb, 0, frag, mask, @params.quality,
                  @params.size_hint.to_i32!, nctx, lmap)
                num_literal_contexts = nctx.value
                literal_context_map = lmap.value
              end
              Enc.build_meta_block_greedy(rb, 0, mask, prev_byte, prev_byte2,
                                          literal_context_mode,
                                          num_literal_contexts,
                                          literal_context_map, commands, mb)
              if @params.quality >= MIN_QUALITY_FOR_OPTIMIZE_HISTOGRAMS
                Enc.optimize_histograms(
                  @params.dist.alphabet_size_limit.to_i32, mb)
              end
              Enc.store_meta_block(arena, context_map_arena, rb, 0, frag,
                                   mask, prev_byte, prev_byte2,
                                   is_last_fragment, @params,
                                   literal_context_mode, commands, mb, w)
              # encode.c:614 — the compressed form lost to a raw copy: roll
              # back and emit the block uncompressed.
              if frag + 4 < (w.pos >> 3)
                dist_cache[0, 4].copy_from(saved_dist_cache)
                storage[0] = (last_bytes & 0xFF).to_u8!
                storage[1] = (last_bytes >> 8).to_u8!
                w.pos = last_bytes_bits.to_i32
                Enc.store_uncompressed_meta_block(is_last_fragment, rb, 0,
                                                  mask, frag, w)
              end
            else
              dist_cache[0, 4].copy_from(saved_dist_cache)
              Enc.store_uncompressed_meta_block(is_last_fragment, rb, 0,
                                                mask, frag, w)
            end
          end

          out_bytes = w.pos >> 3
          out.write(storage[0, out_bytes])
          last_bytes = storage.unsafe_fetch(out_bytes).to_u16
          last_bytes_bits = (w.pos & 7).to_u8!
          break if is_last_fragment || frag == 0
          frag_pos += frag
        end
        out.to_slice
      end

      private def log2_ceil(n : Int32) : Int32
        n <= 1 ? 0 : (n - 1).bit_length # ceil(log2(n))
      end

      # encode.c:495 — ChooseContextMode (q10+ only distinguishes SIGNED).
      private def choose_context_mode(data : Bytes, pos : Int32, mask : Int32,
                                      length : Int32) : Int32
        if @params.quality >= MIN_QUALITY_FOR_HQ_BLOCK_SPLITTING &&
           !Enc.mostly_utf8?(data, pos, mask, length, K_MIN_UTF8_RATIO)
          3 # CONTEXT_SIGNED
        else
          2 # CONTEXT_UTF8
        end
      end

      # encode.c:1118-1145 + WriteMetaBlockInternal, q10/q11 route: Zopfli
      # (single pass) or HQ Zopfli (two passes) backward references with the
      # H10 binary-tree hasher, then the clustered HQ metablock split.
      private def encode_hq(input : Bytes) : Bytes
        lgwin = @params.lgwin
        window = 1 << lgwin

        last_bytes, last_bytes_bits = Enc.encode_window_bits(lgwin)
        out = IO::Memory.new(input.size // 2 + 64)

        # See encode_blocks: the distance cache is continuous across
        # fragments, matching the decoder's ring buffer.
        dist_cache = Slice(Int32).new(Brotli::NUM_DISTANCE_SHORT_CODES)
        dist_cache[0, 4].copy_from(Slice[4, 11, 15, 16])

        frag_pos = 0
        loop do
          frag = Math.min(input.size - frag_pos, window)
          is_last_fragment = frag_pos + frag >= input.size

          rb_bits = Math.max(log2_ceil(frag), 1)
          rb_size = 1 << rb_bits
          # +16 slack: hashers read up to 8 bytes past the logical end.
          rb = Bytes.new(rb_size + 16)
          rb[0, frag].copy_from(input[frag_pos, frag])
          mask = rb_size - 1

          # C: one_shot with input_size < 2^lgwin shrinks the forest.
          num_nodes = Math.min(1 << lgwin, rb_size)
          hasher = BinaryTreeHasher.new(lgwin, num_nodes)
          hasher.prepare(rb, true, frag)
          arena = MetablockArena.new
          context_map_arena = ContextMapArena.new

          storage = Bytes.new(2 &* frag &+ 503)
          storage[0] = (last_bytes & 0xFF).to_u8!
          storage[1] = (last_bytes >> 8).to_u8!
          w = BitWriter.new(storage, last_bytes_bits.to_i32)

          if frag == 0
            # Write the ISLAST and ISEMPTY bits.
            w.write_bits(2, 3)
            w.pos = (w.pos &+ 7) & ~7
          else
            prev_byte = frag_pos > 0 ? input.unsafe_fetch(frag_pos - 1) : 0_u8
            prev_byte2 = frag_pos > 1 ? input.unsafe_fetch(frag_pos - 2) : 0_u8

            saved_dist_cache = dist_cache[0, 4].dup
            commands = [] of Command
            if @params.quality == HQ_ZOPFLIFICATION_QUALITY
              last_insert_len, num_literals =
                Enc.create_hq_zopfli_backward_references(
                  frag, 0, frag_pos, rb, mask, @params, dist_cache, hasher,
                  0, commands)
            else
              last_insert_len, num_literals =
                Enc.create_zopfli_backward_references(
                  frag, 0, frag_pos, rb, mask, @params, dist_cache, hasher,
                  0, commands)
            end
            if last_insert_len > 0
              commands << Command.insert(last_insert_len)
              num_literals += last_insert_len
            end

            if should_compress?(rb, mask, 0, frag, num_literals, commands.size)
              block_params = @params.dup
              literal_context_mode = choose_context_mode(rb, 0, mask, frag)
              mb = MetaBlockSplit.new
              Enc.build_meta_block(rb, 0, mask, block_params, prev_byte,
                                   prev_byte2, commands, commands.size,
                                   literal_context_mode, mb)
              if @params.quality >= MIN_QUALITY_FOR_OPTIMIZE_HISTOGRAMS
                Enc.optimize_histograms(
                  block_params.dist.alphabet_size_limit.to_i32, mb)
              end
              Enc.store_meta_block(arena, context_map_arena, rb, 0, frag,
                                   mask, prev_byte, prev_byte2,
                                   is_last_fragment, block_params,
                                   literal_context_mode, commands, mb, w)
              # encode.c:614 — the compressed form lost to a raw copy: roll
              # back and emit the block uncompressed.
              if frag + 4 < (w.pos >> 3)
                dist_cache[0, 4].copy_from(saved_dist_cache)
                storage[0] = (last_bytes & 0xFF).to_u8!
                storage[1] = (last_bytes >> 8).to_u8!
                w.pos = last_bytes_bits.to_i32
                Enc.store_uncompressed_meta_block(is_last_fragment, rb, 0,
                                                  mask, frag, w)
              end
            else
              dist_cache[0, 4].copy_from(saved_dist_cache)
              Enc.store_uncompressed_meta_block(is_last_fragment, rb, 0,
                                                mask, frag, w)
            end
          end

          out_bytes = w.pos >> 3
          out.write(storage[0, out_bytes])
          last_bytes = storage.unsafe_fetch(out_bytes).to_u16
          last_bytes_bits = (w.pos & 7).to_u8!
          break if is_last_fragment || frag == 0
          frag_pos += frag
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
