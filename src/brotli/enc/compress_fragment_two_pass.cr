# Port of c/enc/compress_fragment_two_pass.{c,h}: quality-1 two-pass
# fragment compressor. First pass records matches into command/literal
# buffers; second pass emits them with prefix codes built from the actual
# histograms. Upstream: 42a2ed4.

module Brotli
  module Enc
    # compress_fragment_two_pass.h — kCompressFragmentTwoPassBlockSize.
    TWO_PASS_BLOCK_SIZE = 1 << 17

    # compress_fragment_two_pass.c:29 — MAX_DISTANCE = MAX_BACKWARD_LIMIT(18).
    TWO_PASS_MAX_DISTANCE = (1 << 18) - Brotli::WINDOW_GAP

    MIN_RATIO = 0.98
    SAMPLE_RATE = 43

    # Control-flow signal for the C `goto emit_remainder` (the remainder
    # section follows the scan loop, so this is a plain early exit).
    private class RemainderSignal < Exception
    end

    # Scratch buffers for the two-pass compressor (C: BrotliTwoPassArena).
    class TwoPassArena
      property lit_histo : Slice(UInt32)
      property lit_depth : Bytes
      property lit_bits : Slice(UInt16)
      property cmd_histo : Slice(UInt32)
      property cmd_depth : Bytes
      property cmd_bits : Slice(UInt16)
      property tmp_tree : Slice(HuffmanTree)
      property tmp_depth : Bytes
      property tmp_bits : Slice(UInt16)

      def initialize
        @lit_histo = Slice(UInt32).new(256)
        @lit_depth = Bytes.new(256)
        @lit_bits = Slice(UInt16).new(256)
        @cmd_histo = Slice(UInt32).new(128)
        @cmd_depth = Bytes.new(128)
        @cmd_bits = Slice(UInt16).new(128)
        @tmp_tree = Slice(HuffmanTree).new(2 * Brotli::NUM_LITERAL_SYMBOLS + 1) do |i|
          HuffmanTree.new
        end
        @tmp_depth = Bytes.new(Brotli::NUM_COMMAND_SYMBOLS)
        @tmp_bits = Slice(UInt16).new(64)
      end
    end

    # compress_fragment_two_pass.c:31 — Hash of `length` (4 or 6) bytes.
    private def self.two_pass_hash(data : Bytes, p : Int32, shift : Int32,
                                    length : Int32) : UInt32
      v = (data.to_unsafe + p).as(Pointer(UInt64)).value
      (((v << ((8 &- length) &* 8)) &* K_HASH_MUL32) >> shift).to_u32!
    end

    # compress_fragment_two_pass.c:38 — HashBytesAtOffset.
    private def self.two_pass_hash_at(v : UInt64, offset : Int32,
                                      shift : Int32, length : Int32) : UInt32
      ((((v >> (8 &* offset)) << ((8 &- length) &* 8)) &* K_HASH_MUL32) >> shift).to_u32!
    end

    private def self.two_pass_is_match?(data : Bytes, p1 : Int32, p2 : Int32,
                                        length : Int32) : Bool
      l1 = (data.to_unsafe + p1).as(Pointer(UInt32)).value
      l2 = (data.to_unsafe + p2).as(Pointer(UInt32)).value
      return false if l1 != l2
      return true if length == 4
      data.unsafe_fetch(p1 &+ 4) == data.unsafe_fetch(p2 &+ 4) &&
        data.unsafe_fetch(p1 &+ 5) == data.unsafe_fetch(p2 &+ 5)
    end

    # compress_fragment_two_pass.c:58 — two 64-symbol trees with the
    # two-pass "emit order" shuffle (DIFFERENT from the one-pass one).
    private def self.two_pass_build_and_store_command_prefix_code(
        s : TwoPassArena, w : BitWriter) : Nil
      cmd_depth = s.cmd_depth
      cmd_bits = s.cmd_bits
      tmp_depth = s.tmp_depth
      tmp_bits = s.tmp_bits
      tmp_depth.fill(0, 0, Brotli::NUM_COMMAND_SYMBOLS)

      create_huffman_tree(s.cmd_histo, 64, 15, s.tmp_tree, cmd_depth)
      create_huffman_tree(s.cmd_histo + 64, 64, 14, s.tmp_tree, cmd_depth + 64)
      # NOTE: the C memcpy sizes are BYTE counts; entries are UInt16 here,
      # so 48 bytes -> 24 symbols, 16 bytes -> 8 symbols.
      tmp_depth[0, 24].copy_from(cmd_depth[24, 24])
      tmp_depth[24, 8].copy_from(cmd_depth[0, 8])
      tmp_depth[32, 8].copy_from(cmd_depth[48, 8])
      tmp_depth[40, 8].copy_from(cmd_depth[8, 8])
      tmp_depth[48, 8].copy_from(cmd_depth[56, 8])
      tmp_depth[56, 8].copy_from(cmd_depth[16, 8])
      convert_bit_depths_to_symbols(tmp_depth, 64, tmp_bits)
      cmd_bits[0, 8].copy_from(tmp_bits[24, 8])
      cmd_bits[8, 8].copy_from(tmp_bits[40, 8])
      cmd_bits[16, 8].copy_from(tmp_bits[56, 8])
      cmd_bits[24, 24].copy_from(tmp_bits[0, 24])
      cmd_bits[48, 8].copy_from(tmp_bits[32, 8])
      cmd_bits[56, 8].copy_from(tmp_bits[48, 8])
      convert_bit_depths_to_symbols(cmd_depth[64, 64], 64, cmd_bits[64, 64])
      # Create the bit length array for the full command alphabet.
      tmp_depth.fill(0, 0, 64) # only 64 first values were used
      tmp_depth[0, 8].copy_from(cmd_depth[24, 8])
      tmp_depth[64, 8].copy_from(cmd_depth[32, 8])
      tmp_depth[128, 8].copy_from(cmd_depth[40, 8])
      tmp_depth[192, 8].copy_from(cmd_depth[48, 8])
      tmp_depth[384, 8].copy_from(cmd_depth[56, 8])
      i = 0
      while i < 8
        tmp_depth[128 &+ 8 &* i] = cmd_depth.unsafe_fetch(i)
        tmp_depth[256 &+ 8 &* i] = cmd_depth.unsafe_fetch(8 &+ i)
        tmp_depth[448 &+ 8 &* i] = cmd_depth.unsafe_fetch(16 &+ i)
        i += 1
      end
      store_huffman_tree(tmp_depth, Brotli::NUM_COMMAND_SYMBOLS, s.tmp_tree, w)
      store_huffman_tree(cmd_depth[64, 64], 64, s.tmp_tree, w)
    end

    # Command buffer encoding: one UInt32 per token, code | extra << 8.
    # The "last distance" marker is the bare value 64.

    private def self.emit_insert_len(insertlen : Int32, commands : Slice(UInt32),
                                     p : Int32) : Int32
      if insertlen < 6
        commands[p] = insertlen.to_u32!
      elsif insertlen < 130
        tail = insertlen - 2
        nbits = Enc.log2_floor_non_zero(tail) - 1
        prefix = tail >> nbits
        inscode = (nbits << 1) + prefix + 2
        commands[p] = inscode.to_u32! | ((tail &- (prefix << nbits)).to_u32! << 8)
      elsif insertlen < 2114
        tail = insertlen - 66
        nbits = Enc.log2_floor_non_zero(tail)
        code = nbits + 10
        commands[p] = code.to_u32! | ((tail &- (1 << nbits)).to_u32! << 8)
      elsif insertlen < 6210
        commands[p] = 21_u32 | ((insertlen &- 2114).to_u32! << 8)
      elsif insertlen < 22594
        commands[p] = 22_u32 | ((insertlen &- 6210).to_u32! << 8)
      else
        commands[p] = 23_u32 | ((insertlen &- 22594).to_u32! << 8)
      end
      p &+ 1
    end

    private def self.emit_copy_len(copylen : Int32, commands : Slice(UInt32),
                                  p : Int32) : Int32
      if copylen < 10
        commands[p] = (copylen &+ 38).to_u32!
        p &+ 1
      elsif copylen < 134
        tail = copylen - 6
        nbits = Enc.log2_floor_non_zero(tail) - 1
        prefix = tail >> nbits
        code = (nbits << 1) + prefix + 44
        commands[p] = code.to_u32! | ((tail &- (prefix << nbits)).to_u32! << 8)
        p &+ 1
      elsif copylen < 2118
        tail = copylen - 70
        nbits = Enc.log2_floor_non_zero(tail)
        code = nbits + 52
        commands[p] = code.to_u32! | ((tail &- (1 << nbits)).to_u32! << 8)
        p &+ 1
      else
        commands[p] = 63_u32 | ((copylen &- 2118).to_u32! << 8)
        p &+ 1
      end
    end

    private def self.emit_copy_len_last_distance(copylen : Int32,
                                                 commands : Slice(UInt32),
                                                 p : Int32) : Int32
      if copylen < 12
        commands[p] = (copylen &+ 20).to_u32!
        p &+ 1
      elsif copylen < 72
        tail = copylen - 8
        nbits = Enc.log2_floor_non_zero(tail) - 1
        prefix = tail >> nbits
        code = (nbits << 1) + prefix + 28
        commands[p] = code.to_u32! | ((tail &- (prefix << nbits)).to_u32! << 8)
        p &+ 1
      elsif copylen < 136
        tail = copylen - 8
        code = (tail >> 5) + 54
        commands[p] = code.to_u32! | ((tail & 31).to_u32! << 8)
        commands[p &+ 1] = 64_u32
        p &+ 2
      elsif copylen < 2120
        tail = copylen - 72
        nbits = Enc.log2_floor_non_zero(tail)
        code = nbits + 52
        commands[p] = code.to_u32! | ((tail &- (1 << nbits)).to_u32! << 8)
        commands[p &+ 1] = 64_u32
        p &+ 2
      else
        commands[p] = 63_u32 | ((copylen &- 2120).to_u32! << 8)
        commands[p &+ 1] = 64_u32
        p &+ 2
      end
    end

    private def self.emit_distance(distance : Int32, commands : Slice(UInt32),
                                   p : Int32) : Int32
      d = distance &+ 3
      nbits = Enc.log2_floor_non_zero(d) - 1
      prefix = (d >> nbits) & 1
      offset = (2 &+ prefix) << nbits
      distcode = 2 &* (nbits &- 1) &+ prefix &+ 80
      commands[p] = distcode.to_u32! | ((d &- offset).to_u32! << 8)
      p &+ 1
    end

    # compress_fragment_two_pass.c:210 — REQUIRES len <= 1 << 24.
    private def self.two_pass_store_meta_block_header(len : Int32,
                                                      is_uncompressed : Bool,
                                                      w : BitWriter) : Nil
      nibbles = 6
      nibbles = 4 if len <= (1 << 16)
      nibbles = 5 if len <= (1 << 20) && nibbles == 6
      w.write_bits(1, 0) # ISLAST
      w.write_bits(2, nibbles - 4)
      w.write_bits(nibbles * 4, (len &- 1).to_u64)
      w.write_bits(1, is_uncompressed ? 1 : 0)
    end

    # compress_fragment_two_pass.c:228 — first pass: scan for matches, fill
    # the command and literal buffers. Returns {lit_pos, cmd_pos}.
    private def self.create_commands(data : Bytes, input : Int32,
                                     block_size : Int32, input_size : Int32,
                                     base_ip : Int32, table : Slice(Int32),
                                     table_bits : Int32, min_match : Int32,
                                     literals : Bytes, lit_pos : Int32,
                                     commands : Slice(UInt32),
                                     cmd_pos : Int32) : {Int32, Int32}
      shift = 64 &- table_bits
      ip_end = input &+ block_size
      next_emit = input
      last_distance = -1
      input_margin_bytes = Brotli::WINDOW_GAP

      begin
        if block_size >= input_margin_bytes
          len_limit = Math.min(block_size &- min_match,
                               input_size &- input_margin_bytes)
          ip_limit = input &+ len_limit

          ip = input
          ip &+= 1
          next_hash = two_pass_hash(data, ip, shift, min_match)
          loop do
            # Step 1: trawl (C `goto trawl` for a too-far candidate folds
            # into the loop, as in the one-pass port).
            candidate = 0
            skip = 32
            next_ip = ip
            loop do
              hash = next_hash
              bytes_between_hash_lookups = skip
              skip &+= 1
              bytes_between_hash_lookups >>= 5
              ip = next_ip
              next_ip = ip &+ bytes_between_hash_lookups
              raise RemainderSignal.new if next_ip > ip_limit
              next_hash = two_pass_hash(data, next_ip, shift, min_match)
              cand = ip &- last_distance
              if two_pass_is_match?(data, ip, cand, min_match) && cand < ip
                table[hash] = ip &- base_ip
                if ip &- cand <= TWO_PASS_MAX_DISTANCE
                  candidate = cand
                  break
                end
                next
              end
              cand = base_ip &+ table[hash]
              table[hash] = ip &- base_ip
              if two_pass_is_match?(data, ip, cand, min_match) &&
                 ip &- cand <= TWO_PASS_MAX_DISTANCE
                candidate = cand
                break
              end
            end

            # Step 2: emit the match and the literals before it.
            base = ip
            matched = min_match &+ find_match_length_with_limit(
              data, candidate &+ min_match, ip &+ min_match,
              (ip_end &- ip) &- min_match)
            distance = base &- candidate # > 0
            insert = base &- next_emit
            ip &+= matched
            cmd_pos = emit_insert_len(insert, commands, cmd_pos)
            literals[lit_pos, insert].copy_from(data[next_emit, insert])
            lit_pos &+= insert
            if distance == last_distance
              commands[cmd_pos] = 64_u32
              cmd_pos &+= 1
            else
              cmd_pos = emit_distance(distance, commands, cmd_pos)
              last_distance = distance
            end
            cmd_pos = emit_copy_len_last_distance(matched, commands, cmd_pos)

            next_emit = ip
            raise RemainderSignal.new if ip >= ip_limit
            # Update the table with hashes inside the last copy. Note: in
            # the min_match == 4 branch C's third prev_hash uses offset 0
            # (not 2) — an upstream quirk; port faithfully.
            if min_match == 4
              input_bytes = (data.to_unsafe + ip - 3).as(Pointer(UInt64)).value
              cur_hash = two_pass_hash_at(input_bytes, 3, shift, min_match)
              prev_hash = two_pass_hash_at(input_bytes, 0, shift, min_match)
              table[prev_hash] = ip &- base_ip &- 3
              prev_hash = two_pass_hash_at(input_bytes, 1, shift, min_match)
              table[prev_hash] = ip &- base_ip &- 2
              prev_hash = two_pass_hash_at(input_bytes, 0, shift, min_match)
              table[prev_hash] = ip &- base_ip &- 1
            else
              input_bytes = (data.to_unsafe + ip - 5).as(Pointer(UInt64)).value
              prev_hash = two_pass_hash_at(input_bytes, 0, shift, min_match)
              table[prev_hash] = ip &- base_ip &- 5
              prev_hash = two_pass_hash_at(input_bytes, 1, shift, min_match)
              table[prev_hash] = ip &- base_ip &- 4
              prev_hash = two_pass_hash_at(input_bytes, 2, shift, min_match)
              table[prev_hash] = ip &- base_ip &- 3
              input_bytes = (data.to_unsafe + ip - 2).as(Pointer(UInt64)).value
              cur_hash = two_pass_hash_at(input_bytes, 2, shift, min_match)
              prev_hash = two_pass_hash_at(input_bytes, 0, shift, min_match)
              table[prev_hash] = ip &- base_ip &- 2
              prev_hash = two_pass_hash_at(input_bytes, 1, shift, min_match)
              table[prev_hash] = ip &- base_ip &- 1
            end
            candidate = base_ip &+ table[cur_hash]
            table[cur_hash] = ip &- base_ip

            while ip &- candidate <= TWO_PASS_MAX_DISTANCE &&
                  two_pass_is_match?(data, ip, candidate, min_match)
              # Match at ip, no literals to emit first.
              base = ip
              matched = min_match &+ find_match_length_with_limit(
                data, candidate &+ min_match, ip &+ min_match,
                (ip_end &- ip) &- min_match)
              ip &+= matched
              last_distance = base &- candidate # > 0
              cmd_pos = emit_copy_len(matched, commands, cmd_pos)
              cmd_pos = emit_distance(last_distance, commands, cmd_pos)

              next_emit = ip
              raise RemainderSignal.new if ip >= ip_limit
              if min_match == 4
                input_bytes = (data.to_unsafe + ip - 3).as(Pointer(UInt64)).value
                cur_hash = two_pass_hash_at(input_bytes, 3, shift, min_match)
                prev_hash = two_pass_hash_at(input_bytes, 0, shift, min_match)
                table[prev_hash] = ip &- base_ip &- 3
                prev_hash = two_pass_hash_at(input_bytes, 1, shift, min_match)
                table[prev_hash] = ip &- base_ip &- 2
                prev_hash = two_pass_hash_at(input_bytes, 2, shift, min_match)
                table[prev_hash] = ip &- base_ip &- 1
              else
                input_bytes = (data.to_unsafe + ip - 5).as(Pointer(UInt64)).value
                prev_hash = two_pass_hash_at(input_bytes, 0, shift, min_match)
                table[prev_hash] = ip &- base_ip &- 5
                prev_hash = two_pass_hash_at(input_bytes, 1, shift, min_match)
                table[prev_hash] = ip &- base_ip &- 4
                prev_hash = two_pass_hash_at(input_bytes, 2, shift, min_match)
                table[prev_hash] = ip &- base_ip &- 3
                input_bytes = (data.to_unsafe + ip - 2).as(Pointer(UInt64)).value
                cur_hash = two_pass_hash_at(input_bytes, 2, shift, min_match)
                prev_hash = two_pass_hash_at(input_bytes, 0, shift, min_match)
                table[prev_hash] = ip &- base_ip &- 2
                prev_hash = two_pass_hash_at(input_bytes, 1, shift, min_match)
                table[prev_hash] = ip &- base_ip &- 1
              end
              candidate = base_ip &+ table[cur_hash]
              table[cur_hash] = ip &- base_ip
            end

            ip &+= 1
            next_hash = two_pass_hash(data, ip, shift, min_match)
          end
        end
      rescue RemainderSignal
        # goto emit_remainder
      end

      # Emit the remaining bytes as literals.
      if next_emit < ip_end
        insert = ip_end &- next_emit
        cmd_pos = emit_insert_len(insert, commands, cmd_pos)
        literals[lit_pos, insert].copy_from(data[next_emit, insert])
        lit_pos &+= insert
      end
      {lit_pos, cmd_pos}
    end

    # compress_fragment_two_pass.c:458 — second pass: build the prefix
    # codes from the actual histograms and emit everything.
    K_NUM_EXTRA_BITS = Slice[
      0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5,
      6, 7, 8, 9, 10, 12, 14, 24, 0, 0, 0, 0, 0, 0, 0, 0,
      1, 1, 2, 2, 3, 3, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0,
      1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
      9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
      17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, 23, 23, 24, 24,
    ].map(&.to_u32!)

    K_INSERT_OFFSET = Slice[
      0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26,
      34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594,
    ].map(&.to_u32!)

    private def self.store_commands(s : TwoPassArena, literals : Bytes,
                                    num_literals : Int32,
                                    commands : Slice(UInt32),
                                    num_commands : Int32, w : BitWriter) : Nil
      s.lit_histo.fill(0)
      s.cmd_depth.fill(0)
      s.cmd_bits.fill(0)
      s.cmd_histo.fill(0)
      i = 0
      while i < num_literals
        s.lit_histo[literals.unsafe_fetch(i)] &+= 1
        i += 1
      end
      build_and_store_huffman_tree_fast(s.tmp_tree, s.lit_histo,
                                        num_literals.to_u64, 8,
                                        s.lit_depth, s.lit_bits, w)

      i = 0
      while i < num_commands
        code = commands.unsafe_fetch(i) & 0xFF
        s.cmd_histo[code] &+= 1
        i += 1
      end
      s.cmd_histo[1] &+= 1
      s.cmd_histo[2] &+= 1
      s.cmd_histo[64] &+= 1
      s.cmd_histo[84] &+= 1
      two_pass_build_and_store_command_prefix_code(s, w)

      lit_i = 0
      i = 0
      while i < num_commands
        cmd = commands.unsafe_fetch(i)
        code = cmd & 0xFF
        extra = cmd >> 8
        w.write_bits(s.cmd_depth.unsafe_fetch(code),
                     s.cmd_bits.unsafe_fetch(code).to_u64)
        w.write_bits(K_NUM_EXTRA_BITS.unsafe_fetch(code), extra.to_u64)
        if code < 24
          insert = K_INSERT_OFFSET.unsafe_fetch(code) &+ extra
          j = 0
          while j < insert
            lit = literals.unsafe_fetch(lit_i)
            w.write_bits(s.lit_depth.unsafe_fetch(lit),
                         s.lit_bits.unsafe_fetch(lit).to_u64)
            lit_i &+= 1
            j &+= 1
          end
        end
        i += 1
      end
    end

    # compress_fragment_two_pass.c:526
    private def self.should_compress?(s : TwoPassArena, data : Bytes,
                                      pos : Int32, input_size : Int32,
                                      num_literals : Int32) : Bool
      return true if num_literals.to_f64 < MIN_RATIO * input_size
      max_total_bit_cost = input_size.to_f64 * 8 * MIN_RATIO / SAMPLE_RATE
      s.lit_histo.fill(0)
      i = pos
      limit = pos &+ input_size
      while i < limit
        s.lit_histo[data.unsafe_fetch(i)] &+= 1
        i += SAMPLE_RATE
      end
      bits_entropy(s.lit_histo, 256) < max_total_bit_cost
    end

    # compress_fragment_two_pass.c:551
    private def self.emit_uncompressed_meta_block(data : Bytes, pos : Int32,
                                                  input_size : Int32,
                                                  w : BitWriter) : Nil
      two_pass_store_meta_block_header(input_size, true, w)
      w.pos = (w.pos &+ 7) & ~7
      w.storage[w.pos >> 3, input_size].copy_from(data[pos, input_size])
      w.pos &+= input_size << 3
      w.storage[w.pos >> 3] = 0
    end

    # compress_fragment_two_pass.c:560/612 — the whole two-pass compressor.
    # The table-size dispatch of the C FOR_TABLE_BITS_ bloat is a no-op:
    # table_bits passes through, min_match follows it.
    def self.compress_fragment_two_pass(s : TwoPassArena, data : Bytes,
                                        input : Int32, input_size : Int32,
                                        is_last : Bool,
                                        command_buf : Slice(UInt32),
                                        literal_buf : Bytes,
                                        table : Slice(Int32),
                                        table_size : Int32,
                                        w : BitWriter) : Nil
      initial_storage_ix = w.pos
      table_bits = Enc.log2_floor_non_zero(table_size)
      min_match = table_bits <= 15 ? 4 : 6

      pos = input
      left = input_size
      while left > 0
        block_size = Math.min(left, TWO_PASS_BLOCK_SIZE)
        lit_pos, cmd_pos = create_commands(
          data, pos, block_size, left, input, table, table_bits, min_match,
          literal_buf, 0, command_buf, 0)
        if should_compress?(s, data, pos, block_size, lit_pos)
          two_pass_store_meta_block_header(block_size, false, w)
          # No block splits, no contexts.
          w.write_bits(13, 0)
          store_commands(s, literal_buf, lit_pos, command_buf, cmd_pos, w)
        else
          emit_uncompressed_meta_block(data, pos, block_size, w)
        end
        pos &+= block_size
        left &-= block_size
      end

      # If output is larger than a single uncompressed block, rewrite it.
      if w.pos &- initial_storage_ix > 31 &+ (input_size << 3)
        w.rewind_bit_position(initial_storage_ix)
        emit_uncompressed_meta_block(data, input, input_size, w)
      end

      if is_last
        w.write_bits(1, 1) # islast
        w.write_bits(1, 1) # isempty
        w.pos = (w.pos &+ 7) & ~7
      end
    end
  end
end
