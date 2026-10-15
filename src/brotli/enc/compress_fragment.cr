# Port of c/enc/compress_fragment.{c,h}: quality-0 one-pass fragment
# compressor (snappy-derived match loop, simple-ish prefix codes, metablock
# merging, uncompressed escape). Upstream: 42a2ed4.

module Brotli
  module Enc
    K_HASH_MUL32 = 0x1E35A7BD_u64

    # compress_fragment.c:30 — the fast path caps distances at window 18.
    FAST_MAX_DISTANCE = (1 << 18) - Brotli::WINDOW_GAP

    # Control-flow signal for the C `goto emit_remainder` (raised at most
    # once per block, never in the match loop itself).
    private class RemainderSignal < Exception
    end

    # encode.c:410
    K_CMD_HISTO_SEED = Slice[
      0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 0, 0, 0, 0].map(&.to_u32!)

    # encode.c:225 — precomputed command/distance prefix codes for the
    # very first block of a stream.
    K_DEFAULT_COMMAND_DEPTHS = Bytes[
      0, 4, 4, 5, 6, 6, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8,
      0, 0, 0, 4, 4, 4, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7,
      7, 7, 10, 10, 10, 10, 10, 10, 0, 4, 4, 5, 5, 5, 6, 6,
      7, 8, 8, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
      5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      6, 6, 6, 6, 6, 6, 5, 5, 5, 5, 5, 5, 4, 4, 4, 4,
      4, 4, 4, 5, 5, 5, 5, 5, 5, 6, 6, 7, 7, 7, 8, 10,
      12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12]

    K_DEFAULT_COMMAND_BITS = Slice[
      0, 0, 8, 9, 3, 35, 7, 71,
      39, 103, 23, 47, 175, 111, 239, 31,
      0, 0, 0, 4, 12, 2, 10, 6,
      13, 29, 11, 43, 27, 59, 87, 55,
      15, 79, 319, 831, 191, 703, 447, 959,
      0, 14, 1, 25, 5, 21, 19, 51,
      119, 159, 95, 223, 479, 991, 63, 575,
      127, 639, 383, 895, 255, 767, 511, 1023,
      14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      27, 59, 7, 39, 23, 55, 30, 1, 17, 9, 25, 5, 0, 8, 4, 12,
      2, 10, 6, 21, 13, 29, 3, 19, 11, 15, 47, 31, 95, 63, 127, 255,
      767, 2815, 1791, 3839, 511, 2559, 1535, 3583, 1023, 3071, 2047,
      4095].map(&.to_u16!)

    K_DEFAULT_COMMAND_CODE = Bytes[
      0xff, 0x77, 0xd5, 0xbf, 0xe7, 0xde, 0xea, 0x9e, 0x51, 0x5d, 0xde, 0xc6,
      0x70, 0x57, 0xbc, 0x58, 0x58, 0x58, 0xd8, 0xd8, 0x58, 0xd5, 0xcb, 0x8c,
      0xea, 0xe0, 0xc3, 0x87, 0x1f, 0x83, 0xc1, 0x60, 0x1c, 0x67, 0xb2, 0xaa,
      0x06, 0x83, 0xc1, 0x60, 0x30, 0x18, 0xcc, 0xa1, 0xce, 0x88, 0x54, 0x94,
      0x46, 0xe1, 0xb0, 0xd0, 0x4e, 0xb2, 0xf7, 0x04, 0x00]

    # Scratch buffers for the one-pass fragment compressor (C:
    # BrotliOnePassArena). Command/distance prefix codes use a 64+64 symbol
    # alphabet in "emit order" (see compress_fragment.h comment).
    class OnePassArena
      property lit_depth : Bytes
      property lit_bits : Slice(UInt16)
      property cmd_depth : Bytes
      property cmd_bits : Slice(UInt16)
      property cmd_histo : Slice(UInt32)
      property cmd_code : Bytes
      property cmd_code_numbits : Int32
      property tree : Slice(HuffmanTree)
      property histogram : Slice(UInt32)
      property tmp_depth : Bytes
      property tmp_bits : Slice(UInt16)

      def initialize
        @lit_depth = Bytes.new(256)
        @lit_bits = Slice(UInt16).new(256)
        @cmd_depth = Bytes.new(128)
        @cmd_bits = Slice(UInt16).new(128)
        @cmd_histo = Slice(UInt32).new(128)
        @cmd_code = Bytes.new(512)
        @cmd_code_numbits = 0
        @tree = Slice(HuffmanTree).new(2 * Brotli::NUM_LITERAL_SYMBOLS + 1) do |i|
          HuffmanTree.new
        end
        @histogram = Slice(UInt32).new(256)
        @tmp_depth = Bytes.new(Brotli::NUM_COMMAND_SYMBOLS)
        @tmp_bits = Slice(UInt16).new(64)
        init_command_prefix_codes
      end

      # encode.c:224 — InitCommandPrefixCodes.
      def init_command_prefix_codes : Nil
        @cmd_depth.copy_from(K_DEFAULT_COMMAND_DEPTHS)
        K_DEFAULT_COMMAND_BITS.each_with_index do |b, i|
          @cmd_bits[i] = b
        end
        @cmd_code.fill(0)
        K_DEFAULT_COMMAND_CODE.each_with_index do |b, i|
          @cmd_code[i] = b
        end
        @cmd_code_numbits = 448
      end
    end

    # Hash of 8 bytes at data[p]: (load64 << 24) * kHashMul32 >> shift.
    private def self.fast_hash(data : Bytes, p : Int32, shift : Int32) : UInt32
      v = (data.to_unsafe + p).as(Pointer(UInt64)).value
      (((v << 24) &* K_HASH_MUL32) >> shift).to_u32!
    end

    # compress_fragment.c:37 — HashBytesAtOffset.
    private def self.hash_bytes_at_offset(v : UInt64, offset : Int32,
                                          shift : Int32) : UInt32
      ((((v >> (8 &* offset)) << 24) &* K_HASH_MUL32) >> shift).to_u32!
    end


    private def self.is_match?(data : Bytes, p1 : Int32, p2 : Int32) : Bool
      l1 = (data.to_unsafe + p1).as(Pointer(UInt32)).value
      l2 = (data.to_unsafe + p2).as(Pointer(UInt32)).value
      l1 == l2 && data.unsafe_fetch(p1 &+ 4) == data.unsafe_fetch(p2 &+ 4)
    end

    # compress_fragment.c:61 — BuildAndStoreLiteralPrefixCode. Returns the
    # estimated ratio, millibytes per symbol.
    private def self.build_and_store_literal_prefix_code(s : OnePassArena,
                                                         data : Bytes,
                                                         input : Int32,
                                                         input_size : Int32,
                                                         w : BitWriter) : Int32
      histogram = s.histogram
      histogram.fill(0)

      if input_size < (1 << 15)
        i = 0
        while i < input_size
          histogram[data.unsafe_fetch(input &+ i)] &+= 1
          i += 1
        end
        histogram_total = input_size.to_u64
        i = 0
        while i < 256
          # Weigh the first 11 samples with weight 3 to account for the
          # balancing effect of the LZ77 phase on the histogram.
          adjust = 2_u32 &* Math.min(histogram.unsafe_fetch(i), 11_u32)
          histogram[i] &+= adjust
          histogram_total &+= adjust
          i += 1
        end
      else
        sample_rate = 29
        i = 0
        while i < input_size
          histogram[data.unsafe_fetch(input &+ i)] &+= 1
          i += sample_rate
        end
        histogram_total = ((input_size + sample_rate - 1) // sample_rate).to_u64
        i = 0
        while i < 256
          # Add 1 to each count to avoid 0 bit depths (this is only a
          # sample), plus the weight-3 boost for the first 11.
          adjust = 1_u32 &+ (2_u32 &* Math.min(histogram.unsafe_fetch(i), 11_u32))
          histogram[i] &+= adjust
          histogram_total &+= adjust
          i += 1
        end
      end

      build_and_store_huffman_tree_fast(s.tree, histogram, histogram_total, 8,
                                        s.lit_depth, s.lit_bits, w)

      literal_ratio = 0_u64
      i = 0
      while i < 256
        if histogram[i] != 0
          literal_ratio &+= histogram[i].to_u64 &* s.lit_depth[i]
        end
        i += 1
      end
      # Estimated encoding ratio, millibytes per symbol.
      ((literal_ratio &* 125) // histogram_total).to_i32!
    end

    # compress_fragment.c:117 — two 64-symbol trees (command + distance)
    # with the "emit order" shuffle.
    private def self.build_and_store_command_prefix_code(s : OnePassArena,
                                                         w : BitWriter) : Nil
      histogram = s.cmd_histo
      depth = s.cmd_depth
      bits = s.cmd_bits
      tmp_depth = s.tmp_depth
      tmp_bits = s.tmp_bits
      tmp_depth.fill(0, 0, Brotli::NUM_COMMAND_SYMBOLS)

      create_huffman_tree(histogram, 64, 15, s.tree, depth)
      create_huffman_tree(histogram + 64, 64, 14, s.tree, depth + 64)
      # The symbols are in a different order than in the full alphabet;
      # having them in this order in cmd_bits saves branches in Emit*.
      tmp_depth.copy_from(depth[0, 24])
      tmp_depth[24, 8].copy_from(depth[40, 8])
      tmp_depth[32, 8].copy_from(depth[24, 8])
      tmp_depth[40, 8].copy_from(depth[48, 8])
      tmp_depth[48, 8].copy_from(depth[32, 8])
      tmp_depth[56, 8].copy_from(depth[56, 8])
      convert_bit_depths_to_symbols(tmp_depth, 64, tmp_bits)
      # NOTE: the C memcpy sizes are BYTE counts; entries are UInt16 here,
      # so 48 bytes -> 24 symbols, 16 bytes -> 8 symbols.
      bits.copy_from(tmp_bits[0, 24])
      bits[24, 8].copy_from(tmp_bits[32, 8])
      bits[32, 8].copy_from(tmp_bits[48, 8])
      bits[40, 8].copy_from(tmp_bits[24, 8])
      bits[48, 8].copy_from(tmp_bits[40, 8])
      bits[56, 8].copy_from(tmp_bits[56, 8])
      convert_bit_depths_to_symbols(depth[64, 64], 64, bits[64, 64])

      # Create the bit length array for the full command alphabet.
      tmp_depth.fill(0, 0, 64) # only 64 first values were used
      tmp_depth.copy_from(depth[0, 8])
      tmp_depth[64, 8].copy_from(depth[8, 8])
      tmp_depth[128, 8].copy_from(depth[16, 8])
      tmp_depth[192, 8].copy_from(depth[24, 8])
      tmp_depth[384, 8].copy_from(depth[32, 8])
      i = 0
      while i < 8
        tmp_depth[128 &+ 8 &* i] = depth.unsafe_fetch(40 &+ i)
        tmp_depth[256 &+ 8 &* i] = depth.unsafe_fetch(48 &+ i)
        tmp_depth[448 &+ 8 &* i] = depth.unsafe_fetch(56 &+ i)
        i += 1
      end
      store_huffman_tree(tmp_depth, Brotli::NUM_COMMAND_SYMBOLS, s.tree, w)
      store_huffman_tree(depth[64, 64], 64, s.tree, w)
    end

    # REQUIRES: insertlen < 6210
    private def self.emit_insert_len(insertlen : Int32, cmd_depth : Bytes,
                                     cmd_bits : Slice(UInt16),
                                     cmd_histo : Slice(UInt32),
                                     w : BitWriter) : Nil
      if insertlen < 6
        code = insertlen + 40
        w.write_bits(cmd_depth[code], cmd_bits[code].to_u64)
        cmd_histo[code] &+= 1
      elsif insertlen < 130
        tail = insertlen - 2
        nbits = Enc.log2_floor_non_zero(tail) - 1
        prefix = tail >> nbits
        inscode = (nbits << 1) + prefix + 42
        w.write_bits(cmd_depth[inscode], cmd_bits[inscode].to_u64)
        w.write_bits(nbits, (tail - (prefix << nbits)).to_u64)
        cmd_histo[inscode] &+= 1
      elsif insertlen < 2114
        tail = insertlen - 66
        nbits = Enc.log2_floor_non_zero(tail)
        code = nbits + 50
        w.write_bits(cmd_depth[code], cmd_bits[code].to_u64)
        w.write_bits(nbits, (tail - (1 << nbits)).to_u64)
        cmd_histo[code] &+= 1
      else
        w.write_bits(cmd_depth[61], cmd_bits[61].to_u64)
        w.write_bits(12, (insertlen - 2114).to_u64)
        cmd_histo[61] &+= 1
      end
    end

    private def self.emit_long_insert_len(insertlen : Int32, cmd_depth : Bytes,
                                          cmd_bits : Slice(UInt16),
                                          cmd_histo : Slice(UInt32),
                                          w : BitWriter) : Nil
      if insertlen < 22594
        w.write_bits(cmd_depth[62], cmd_bits[62].to_u64)
        w.write_bits(14, (insertlen - 6210).to_u64)
        cmd_histo[62] &+= 1
      else
        w.write_bits(cmd_depth[63], cmd_bits[63].to_u64)
        w.write_bits(24, (insertlen - 22594).to_u64)
        cmd_histo[63] &+= 1
      end
    end

    private def self.emit_copy_len(copylen : Int32, cmd_depth : Bytes,
                                   cmd_bits : Slice(UInt16),
                                   cmd_histo : Slice(UInt32),
                                   w : BitWriter) : Nil
      if copylen < 10
        w.write_bits(cmd_depth[copylen + 14], cmd_bits[copylen + 14].to_u64)
        cmd_histo[copylen + 14] &+= 1
      elsif copylen < 134
        tail = copylen - 6
        nbits = Enc.log2_floor_non_zero(tail) - 1
        prefix = tail >> nbits
        code = (nbits << 1) + prefix + 20
        w.write_bits(cmd_depth[code], cmd_bits[code].to_u64)
        w.write_bits(nbits, (tail - (prefix << nbits)).to_u64)
        cmd_histo[code] &+= 1
      elsif copylen < 2118
        tail = copylen - 70
        nbits = Enc.log2_floor_non_zero(tail)
        code = nbits + 28
        w.write_bits(cmd_depth[code], cmd_bits[code].to_u64)
        w.write_bits(nbits, (tail - (1 << nbits)).to_u64)
        cmd_histo[code] &+= 1
      else
        w.write_bits(cmd_depth[39], cmd_bits[39].to_u64)
        w.write_bits(24, (copylen - 2118).to_u64)
        cmd_histo[39] &+= 1
      end
    end

    private def self.emit_copy_len_last_distance(copylen : Int32,
                                                 cmd_depth : Bytes,
                                                 cmd_bits : Slice(UInt16),
                                                 cmd_histo : Slice(UInt32),
                                                 w : BitWriter) : Nil
      if copylen < 12
        w.write_bits(cmd_depth[copylen - 4], cmd_bits[copylen - 4].to_u64)
        cmd_histo[copylen - 4] &+= 1
      elsif copylen < 72
        tail = copylen - 8
        nbits = Enc.log2_floor_non_zero(tail) - 1
        prefix = tail >> nbits
        code = (nbits << 1) + prefix + 4
        w.write_bits(cmd_depth[code], cmd_bits[code].to_u64)
        w.write_bits(nbits, (tail - (prefix << nbits)).to_u64)
        cmd_histo[code] &+= 1
      elsif copylen < 136
        tail = copylen - 8
        code = (tail >> 5) + 30
        w.write_bits(cmd_depth[code], cmd_bits[code].to_u64)
        w.write_bits(5, (tail & 31).to_u64)
        w.write_bits(cmd_depth[64], cmd_bits[64].to_u64)
        cmd_histo[code] &+= 1
        cmd_histo[64] &+= 1
      elsif copylen < 2120
        tail = copylen - 72
        nbits = Enc.log2_floor_non_zero(tail)
        code = nbits + 28
        w.write_bits(cmd_depth[code], cmd_bits[code].to_u64)
        w.write_bits(nbits, (tail - (1 << nbits)).to_u64)
        w.write_bits(cmd_depth[64], cmd_bits[64].to_u64)
        cmd_histo[code] &+= 1
        cmd_histo[64] &+= 1
      else
        w.write_bits(cmd_depth[39], cmd_bits[39].to_u64)
        w.write_bits(24, (copylen - 2120).to_u64)
        w.write_bits(cmd_depth[64], cmd_bits[64].to_u64)
        cmd_histo[39] &+= 1
        cmd_histo[64] &+= 1
      end
    end

    private def self.emit_distance(distance : Int32, cmd_depth : Bytes,
                                   cmd_bits : Slice(UInt16),
                                   cmd_histo : Slice(UInt32),
                                   w : BitWriter) : Nil
      d = distance + 3
      nbits = Enc.log2_floor_non_zero(d) - 1
      prefix = (d >> nbits) & 1
      offset = (2 + prefix) << nbits
      distcode = 2 * (nbits - 1) + prefix + 80
      w.write_bits(cmd_depth[distcode], cmd_bits[distcode].to_u64)
      w.write_bits(nbits, (d - offset).to_u64)
      cmd_histo[distcode] &+= 1
    end

    private def self.emit_literals(data : Bytes, pos : Int32, len : Int32,
                                   depth : Bytes, bits : Slice(UInt16),
                                   w : BitWriter) : Nil
      j = 0
      while j < len
        lit = data.unsafe_fetch(pos &+ j)
        w.write_bits(depth[lit], bits[lit].to_u64)
        j += 1
      end
    end

    # REQUIRES: len <= 1 << 24.
    private def self.store_meta_block_header(len : Int32, is_uncompressed : Bool,
                                              w : BitWriter) : Nil
      nibbles = 6
      nibbles = 4 if len <= (1 << 16)
      nibbles = 5 if len <= (1 << 20) && nibbles == 6
      # ISLAST
      w.write_bits(1, 0)
      w.write_bits(2, nibbles - 4)
      w.write_bits(nibbles * 4, (len - 1).to_u64)
      # ISUNCOMPRESSED
      w.write_bits(1, is_uncompressed ? 1 : 0)
    end

    private def self.should_merge_block?(s : OnePassArena, data : Bytes,
                                         pos : Int32, len : Int32,
                                         depths : Bytes) : Bool
      histogram = s.histogram
      sample_rate = 43
      histogram.fill(0)
      i = 0
      while i < len
        histogram[data.unsafe_fetch(pos &+ i)] &+= 1
        i += sample_rate
      end
      total = (len + sample_rate - 1) // sample_rate
      r = (Enc.fast_log2(total) + 0.5) * total + 200
      i = 0
      while i < 256
        if histogram[i] != 0
          r -= histogram[i].to_f64 * (depths[i] + Enc.fast_log2(histogram[i]))
        end
        i += 1
      end
      r >= 0.0
    end

    # Acceptable loss for uncompressible speedup is 2%.
    FAST_MIN_RATIO = 980

    private def self.should_use_uncompressed_mode?(compressed : Int32,
                                                   insertlen : Int32,
                                                   literal_ratio : Int32) : Bool
      return false if compressed &* 50 > insertlen
      literal_ratio > FAST_MIN_RATIO
    end

    private def self.emit_uncompressed_meta_block(data : Bytes, block_start : Int32,
                                                  block_end : Int32,
                                                  storage_ix_start : Int32,
                                                  w : BitWriter) : Nil
      len = block_end - block_start
      w.rewind_bit_position(storage_ix_start)
      store_meta_block_header(len, true, w)
      w.pos = (w.pos &+ 7) & ~7
      w.storage[w.pos >> 3, len].copy_from(data[block_start, len])
      w.pos &+= len << 3
      w.storage[w.pos >> 3] = 0
    end

    # compress_fragment.c:419 — the whole one-pass compressor, ported as a
    # small state machine over the C labels (emit_commands / emit_remainder
    # / next_block); the `goto trawl` distance retry folds into the scan
    # loop. Pointers become indices into `data`.
    def self.compress_fragment_fast_impl(s : OnePassArena, data : Bytes,
                                         input : Int32, input_size : Int32,
                                         is_last : Bool, table : Slice(Int32),
                                         table_bits : Int32, w : BitWriter) : Nil
      cmd_depth = s.cmd_depth
      cmd_bits = s.cmd_bits
      cmd_histo = s.cmd_histo
      lit_depth = s.lit_depth
      lit_bits = s.lit_bits

      first_block_size = 3 << 15
      merge_block_size = 1 << 16

      input_margin_bytes = Brotli::WINDOW_GAP # 16
      min_match_len = 5

      shift = 64 - table_bits

      # Mutable across the state machine (C advances its pointers).
      pos = input       # the `input` pointer in C
      pos_left = input_size
      block_size = Math.min(input_size, first_block_size)
      total_block_size = block_size
      metablock_start = input
      next_emit = input
      base_ip = input
      mlen_storage_ix = w.pos &+ 3
      literal_ratio = 0
      last_ip_end = input # ip_end of the block scanned last

      # First metablock header + prefix codes.
      store_meta_block_header(block_size, false, w)
      w.write_bits(13, 0) # no block splits, no contexts
      literal_ratio = build_and_store_literal_prefix_code(
        s, data, pos, block_size, w)
      # Store the pre-compressed command and distance prefix codes.
      i = 0
      while i &+ 7 < s.cmd_code_numbits
        w.write_bits(8, s.cmd_code[i >> 3].to_u64)
        i &+= 8
      end
      w.write_bits(s.cmd_code_numbits & 7,
                   s.cmd_code[s.cmd_code_numbits >> 3].to_u64)

      state = :emit_commands
      while state != :exit
        case state
        when :emit_commands
          # C label emit_commands: reset histograms, rescan from `pos`.
          cmd_histo.copy_from(K_CMD_HISTO_SEED)

          ip = pos
          last_distance = -1
          ip_end = pos &+ block_size
          last_ip_end = ip_end
          candidate = 0

          escaped = false
          begin
            if block_size >= input_margin_bytes
              # Keep a 16-byte margin for the last block (all distances
              # <= window size - 16), 5 bytes for intermediate blocks.
              len_limit = Math.min(block_size - min_match_len,
                                   pos_left - input_margin_bytes)
              ip_limit = pos &+ len_limit

              ip &+= 1
              next_hash = fast_hash(data, ip, shift)
              loop do
                # Step 1: scan forward for a 5-byte match with heuristic
                # skipping (skip++ >> 5). C's `goto trawl` (match too far)
                # is a plain restart of this inner loop; the do-while's
                # break conditions end it.
                skip = 32
                next_ip = ip
                loop do
                  hash = next_hash
                  bytes_between_hash_lookups = skip
                  skip &+= 1
                  bytes_between_hash_lookups >>= 5
                  ip = next_ip
                  next_ip = ip &+ bytes_between_hash_lookups
                  if next_ip > ip_limit
                    raise RemainderSignal.new
                  end
                  next_hash = fast_hash(data, next_ip, shift)
                  # Last-distance candidate first.
                  cand = ip &- last_distance
                  if is_match?(data, ip, cand) && cand < ip
                    table[hash] = ip &- base_ip
                    if ip &- cand <= FAST_MAX_DISTANCE
                      candidate = cand
                      break
                    end
                    next
                  end
                  cand = base_ip &+ table[hash]
                  table[hash] = ip &- base_ip
                  if is_match?(data, ip, cand) &&
                     ip &- cand <= FAST_MAX_DISTANCE
                    candidate = cand
                    break
                  end
                end

                # Step 2: emit the match with literals in [next_emit, ip).
                base = ip
                matched = 5 &+ find_match_length_with_limit(
                  data, candidate &+ 5, ip &+ 5, (ip_end &- ip) &- 5)
                distance = base &- candidate # > 0
                insert = base &- next_emit
                ip &+= matched
                if insert < 6210
                  emit_insert_len(insert, cmd_depth, cmd_bits, cmd_histo, w)
                elsif should_use_uncompressed_mode?(
                    next_emit &- metablock_start, insert, literal_ratio)
                  emit_uncompressed_meta_block(
                    data, metablock_start, base, mlen_storage_ix &- 3, w)
                  pos_left &-= (base &- pos)
                  pos = base
                  next_emit = pos
                  escaped = true
                  raise RemainderSignal.new
                else
                  emit_long_insert_len(insert, cmd_depth, cmd_bits, cmd_histo, w)
                end
                emit_literals(data, next_emit, insert, lit_depth, lit_bits, w)
                if distance == last_distance
                  w.write_bits(cmd_depth[64], cmd_bits[64].to_u64)
                  cmd_histo[64] &+= 1
                else
                  emit_distance(distance, cmd_depth, cmd_bits, cmd_histo, w)
                  last_distance = distance
                end
                emit_copy_len_last_distance(matched, cmd_depth, cmd_bits,
                                            cmd_histo, w)

                next_emit = ip
                raise RemainderSignal.new if ip >= ip_limit
                # Update the table with hashes inside the last copy.
                input_bytes = (data.to_unsafe + ip - 3).as(Pointer(UInt64)).value
                prev_hash = hash_bytes_at_offset(input_bytes, 0, shift)
                cur_hash = hash_bytes_at_offset(input_bytes, 3, shift)
                table[prev_hash] = ip &- base_ip &- 3
                prev_hash = hash_bytes_at_offset(input_bytes, 1, shift)
                table[prev_hash] = ip &- base_ip &- 2
                prev_hash = hash_bytes_at_offset(input_bytes, 2, shift)
                table[prev_hash] = ip &- base_ip &- 1

                candidate = base_ip &+ table[cur_hash]
                table[cur_hash] = ip &- base_ip

                while is_match?(data, ip, candidate)
                  # 5-byte match at ip, no literals to emit first.
                  base = ip
                  matched = 5 &+ find_match_length_with_limit(
                    data, candidate &+ 5, ip &+ 5, (ip_end &- ip) &- 5)
                  break if ip &- candidate > FAST_MAX_DISTANCE
                  ip &+= matched
                  last_distance = base &- candidate
                  emit_copy_len(matched, cmd_depth, cmd_bits, cmd_histo, w)
                  emit_distance(last_distance, cmd_depth, cmd_bits, cmd_histo, w)

                  next_emit = ip
                  raise RemainderSignal.new if ip >= ip_limit
                  input_bytes = (data.to_unsafe + ip - 3).as(Pointer(UInt64)).value
                  prev_hash = hash_bytes_at_offset(input_bytes, 0, shift)
                  cur_hash = hash_bytes_at_offset(input_bytes, 3, shift)
                  table[prev_hash] = ip &- base_ip &- 3
                  prev_hash = hash_bytes_at_offset(input_bytes, 1, shift)
                  table[prev_hash] = ip &- base_ip &- 2
                  prev_hash = hash_bytes_at_offset(input_bytes, 2, shift)
                  table[prev_hash] = ip &- base_ip &- 1

                  candidate = base_ip &+ table[cur_hash]
                  table[cur_hash] = ip &- base_ip
                end

                ip &+= 1
                next_hash = fast_hash(data, ip, shift)
              end
            end
          rescue RemainderSignal
            # goto emit_remainder
          end
          if escaped
            state = :next_block
          else
            state = :emit_remainder
          end

        when :emit_remainder
          # C label emit_remainder. `last_ip_end` is this block's end.
          pos &+= block_size
          pos_left &-= block_size
          block_size = Math.min(pos_left, merge_block_size)

          # Maybe extend this meta-block with the next block instead of
          # emitting the last insert-only command. Possible because both
          # sizes use 5 nibbles.
          if pos_left > 0 && total_block_size &+ block_size <= (1 << 20) &&
             should_merge_block?(s, data, pos, block_size, lit_depth)
            total_block_size &+= block_size
            w.update_bits(20, (total_block_size &- 1).to_u32!, mlen_storage_ix)
            state = :emit_commands
            next
          end

          # Emit the remaining bytes as literals.
          if next_emit < last_ip_end
            insert = last_ip_end &- next_emit
            if insert < 6210
              emit_insert_len(insert, cmd_depth, cmd_bits, cmd_histo, w)
              emit_literals(data, next_emit, insert, lit_depth, lit_bits, w)
            elsif should_use_uncompressed_mode?(
                next_emit &- metablock_start, insert, literal_ratio)
              emit_uncompressed_meta_block(
                data, metablock_start, last_ip_end, mlen_storage_ix &- 3, w)
            else
              emit_long_insert_len(insert, cmd_depth, cmd_bits, cmd_histo, w)
              emit_literals(data, next_emit, insert, lit_depth, lit_bits, w)
            end
          end
          next_emit = last_ip_end
          state = :next_block

        when :next_block
          # C label next_block: start a fresh meta-block or finish.
          if pos_left > 0
            metablock_start = pos
            block_size = Math.min(pos_left, first_block_size)
            total_block_size = block_size
            mlen_storage_ix = w.pos &+ 3
            store_meta_block_header(block_size, false, w)
            w.write_bits(13, 0)
            literal_ratio = build_and_store_literal_prefix_code(
              s, data, pos, block_size, w)
            build_and_store_command_prefix_code(s, w)
            state = :emit_commands
          else
            state = :exit
          end
        end
      end

      unless is_last
        # Update the command and distance prefix codes for the next block
        # and store the compressed forms.
        s.cmd_code[0] = 0
        code_w = BitWriter.new(s.cmd_code, 0)
        build_and_store_command_prefix_code(s, code_w)
        s.cmd_code_numbits = code_w.pos
      end
    end

    # compress_fragment.c:747 — BrotliCompressFragmentFast entry (the
    # table-size dispatch of the C FOR_TABLE_BITS_ bloat is a no-op in the
    # port: table_bits is passed through).
    def self.compress_fragment_fast(s : OnePassArena, data : Bytes,
                                    input : Int32, input_size : Int32,
                                    is_last : Bool, table : Slice(Int32),
                                    table_size : Int32, w : BitWriter) : Nil
      initial_storage_ix = w.pos
      table_bits = Enc.log2_floor_non_zero(table_size)

      if input_size == 0
        w.write_bits(1, 1) # islast
        w.write_bits(1, 1) # isempty
        w.pos = (w.pos &+ 7) & ~7
        return
      end

      compress_fragment_fast_impl(s, data, input, input_size, is_last,
                                  table, table_bits, w)

      # If output is larger than a single uncompressed block, rewrite it.
      if w.pos &- initial_storage_ix > 31 &+ (input_size << 3)
        emit_uncompressed_meta_block(data, input, input &+ input_size,
                                     initial_storage_ix, w)
      end

      if is_last
        w.write_bits(1, 1) # islast
        w.write_bits(1, 1) # isempty
        w.pos = (w.pos &+ 7) & ~7
      end
    end
  end
end
