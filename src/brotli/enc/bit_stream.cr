# Port of the c/enc/brotli_bit_stream.c subset needed by the q0/q1 fast
# fragment compressors (E2/E3): BrotliBuildAndStoreHuffmanTreeFast and
# BrotliStoreHuffmanTree. More arrives with the q2+ pipeline (E4/E5).
# Upstream: 42a2ed4.

module Brotli
  module Enc
    # brotli_bit_stream.c:169 — order the code-length-code lengths are
    # stored in (kStorageOrder).
    K_STORAGE_ORDER = Bytes[1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12,
                            13, 14, 15]

    # Static Huffman code over the code length alphabet lengths:
    # symbol -> {bits_value, bit_length}.
    K_HUFFMAN_BIT_LENGTH_HUFFMAN_CODE_SYMBOLS = Slice[0_u8, 7_u8, 3_u8, 2_u8, 1_u8, 15_u8]
    K_HUFFMAN_BIT_LENGTH_HUFFMAN_CODE_BIT_LENGTHS = Slice[2_u8, 4_u8, 3_u8, 2_u8, 2_u8, 4_u8]

    # entropy_encode_static.h: StoreStaticCodeLengthCode.
    def self.store_static_code_length_code(w : BitWriter) : Nil
      w.write_bits(40, 0x0000FF55555554_u64)
    end

    # brotli_bit_stream.c:165 — BrotliStoreHuffmanTreeOfHuffmanTreeToBitMask.
    def self.store_huffman_tree_of_huffman_tree_to_bit_mask(
        num_codes : Int32, code_length_bitdepth : Bytes, w : BitWriter) : Nil
      skip_some = 0 # skips none.

      # Throw away trailing zeros:
      codes_to_store = Brotli::CODE_LENGTH_CODES
      if num_codes > 1
        while codes_to_store > 0 &&
              code_length_bitdepth[K_STORAGE_ORDER[codes_to_store - 1]] == 0
          codes_to_store -= 1
        end
      end
      if code_length_bitdepth[K_STORAGE_ORDER[0]] == 0 &&
         code_length_bitdepth[K_STORAGE_ORDER[1]] == 0
        skip_some = 2 # skips two.
        if code_length_bitdepth[K_STORAGE_ORDER[2]] == 0
          skip_some = 3 # skips three.
        end
      end
      w.write_bits(2, skip_some)
      i = skip_some
      while i < codes_to_store
        l = code_length_bitdepth[K_STORAGE_ORDER[i]]
        w.write_bits(K_HUFFMAN_BIT_LENGTH_HUFFMAN_CODE_BIT_LENGTHS[l],
                     K_HUFFMAN_BIT_LENGTH_HUFFMAN_CODE_SYMBOLS[l].to_u64)
        i += 1
      end
    end

    # brotli_bit_stream.c:220 — BrotliStoreHuffmanTreeToBitMask.
    def self.store_huffman_tree_to_bit_mask(huffman_tree_size : Int32,
                                            huffman_tree : Bytes,
                                            huffman_tree_extra_bits : Bytes,
                                            code_length_bitdepth : Bytes,
                                            code_length_bitdepth_symbols : Slice(UInt16),
                                            w : BitWriter) : Nil
      i = 0
      while i < huffman_tree_size
        ix = huffman_tree[i]
        w.write_bits(code_length_bitdepth[ix],
                     code_length_bitdepth_symbols[ix].to_u64)
        # Extra bits
        case ix
        when Brotli::REPEAT_PREVIOUS_CODE_LENGTH
          w.write_bits(2, huffman_tree_extra_bits[i])
        when Brotli::REPEAT_ZERO_CODE_LENGTH
          w.write_bits(3, huffman_tree_extra_bits[i])
        end
        i += 1
      end
    end

    # brotli_bit_stream.c:283 — BrotliStoreHuffmanTree: serializes code
    # lengths `depths[0, num]` (RLE + a second Huffman code over the
    # code-length alphabet). `tree` is scratch (>= 2*18+1 entries).
    def self.store_huffman_tree(depths : Bytes, num : Int32,
                                tree : Slice(HuffmanTree), w : BitWriter) : Nil
      huffman_tree = Bytes.new(Brotli::NUM_COMMAND_SYMBOLS)
      huffman_tree_extra_bits = Bytes.new(Brotli::NUM_COMMAND_SYMBOLS)
      huffman_tree_size = write_huffman_tree(depths, num, huffman_tree,
                                             huffman_tree_extra_bits)

      code_length_bitdepth = Bytes.new(Brotli::CODE_LENGTH_CODES)
      code_length_bitdepth_symbols = Slice(UInt16).new(Brotli::CODE_LENGTH_CODES)
      huffman_tree_histogram = Slice(UInt32).new(Brotli::CODE_LENGTH_CODES)

      # Calculate the statistics of the Huffman tree in brotli-representation.
      i = 0
      while i < huffman_tree_size
        huffman_tree_histogram[huffman_tree[i]] &+= 1
        i += 1
      end

      num_codes = 0
      code = 0
      i = 0
      while i < Brotli::CODE_LENGTH_CODES
        if huffman_tree_histogram[i] != 0
          if num_codes == 0
            code = i
            num_codes = 1
          elsif num_codes == 1
            num_codes = 2
            break
          end
        end
        i += 1
      end

      # Calculate another Huffman tree to compress the first one with.
      create_huffman_tree(huffman_tree_histogram, Brotli::CODE_LENGTH_CODES,
                          5, tree, code_length_bitdepth)
      convert_bit_depths_to_symbols(code_length_bitdepth,
                                    Brotli::CODE_LENGTH_CODES,
                                    code_length_bitdepth_symbols)

      # Now, we have all the data, let's start storing it.
      store_huffman_tree_of_huffman_tree_to_bit_mask(
        num_codes, code_length_bitdepth, w)

      if num_codes == 1
        code_length_bitdepth[code] = 0
      end

      # Store the real Huffman tree now.
      store_huffman_tree_to_bit_mask(huffman_tree_size, huffman_tree,
                                     huffman_tree_extra_bits,
                                     code_length_bitdepth,
                                     code_length_bitdepth_symbols, w)
    end

    # brotli_bit_stream.c:404 — BrotliBuildAndStoreHuffmanTreeFast: builds a
    # depth-limited (14 bits) tree from a histogram that sums to
    # histogram_total and stores it, using the static code-length code when
    # the alphabet is large. `tree` needs 2*length+1 entries.
    def self.build_and_store_huffman_tree_fast(tree : Slice(HuffmanTree),
                                               histogram : Slice(UInt32),
                                               histogram_total : UInt64,
                                               max_bits : Int32,
                                               depth : Bytes,
                                               bits : Slice(UInt16),
                                               w : BitWriter) : Nil
      count = 0
      symbols = StaticArray(UInt32, 4).new(0_u32)
      length = 0
      total = histogram_total
      while total != 0
        if histogram[length] != 0
          symbols[count] = length.to_u32 if count < 4
          count += 1
          total &-= histogram[length]
        end
        length += 1
      end

      if count <= 1
        w.write_bits(4, 1) # simple code, 1 symbol
        w.write_bits(max_bits, symbols[0].to_u64)
        depth[symbols[0]] = 0
        bits[symbols[0]] = 0
        return
      end

      depth.fill(0, 0, length)

      # Inline 14-bit-limited tree build (brotli_bit_stream.c:435). The
      # sort comparator here is count-only (no value tie-break), unlike
      # create_huffman_tree — keep it separate for determinism.
      count_limit = 1_u32
      loop do
        node = 0
        l = length
        while l != 0
          l -= 1
          if histogram[l] != 0
            c = histogram[l] >= count_limit ? histogram[l] : count_limit
            tree[node] = HuffmanTree.new(c, -1_i16, l.to_i16)
            node += 1
          end
        end

        n = node
        i = 0     # Points to the next leaf node.
        j = n + 1 # Points to the next non-leaf node.

        sort_huffman_tree_items(tree, n) { |v0, v1| v0.total_count < v1.total_count }

        sentinel = HuffmanTree.new(UInt32::MAX, -1_i16, -1_i16)
        tree[n] = sentinel
        tree[n + 1] = sentinel
        node = n + 2 # running "next free slot", mirrors C's node pointer

        k = n - 1
        while k > 0
          if tree[i].total_count <= tree[j].total_count
            left = i
            i += 1
          else
            left = j
            j += 1
          end
          if tree[i].total_count <= tree[j].total_count
            right = i
            i += 1
          else
            right = j
            j += 1
          end
          # The sentinel node becomes the parent node.
          tree[node - 1] = HuffmanTree.new(
            tree[left].total_count &+ tree[right].total_count,
            left.to_i16, right.to_i16)
          # Add back the last sentinel node.
          tree[node] = sentinel
          node += 1
          k -= 1
        end
        break if set_depth(2 * n - 1, tree, depth, 14)
        count_limit = count_limit &* 2
      end

      convert_bit_depths_to_symbols(depth, length, bits)
      if count <= 4
        # value of 1 indicates a simple Huffman code
        w.write_bits(2, 1)
        w.write_bits(2, count - 1) # NSYM - 1

        # Sort (descending depth, i.e. ascending... C: swap if depth[j] < depth[i])
        i = 0
        while i < count
          j = i + 1
          while j < count
            if depth[symbols[j]] < depth[symbols[i]]
              symbols[j], symbols[i] = symbols[i], symbols[j]
            end
            j += 1
          end
          i += 1
        end

        count.times { |c| w.write_bits(max_bits, symbols[c].to_u64) }
        # tree-select
        if count == 4
          w.write_bits(1, depth[symbols[0]] == 1 ? 1 : 0)
        end
      else
        previous_value = 8_u8
        # Complex Huffman Tree
        store_static_code_length_code(w)

        # Actual RLE coding.
        i = 0
        while i < length
          value = depth[i]
          reps = 1
          k = i + 1
          while k < length && depth[k] == value
            reps += 1
            k += 1
          end
          i += reps
          if value == 0
            w.write_bits(ZERO_REPS_DEPTH[reps], ZERO_REPS_BITS[reps])
          else
            if previous_value != value
              w.write_bits(CODE_LENGTH_DEPTH[value], CODE_LENGTH_BITS[value])
              reps -= 1
            end
            if reps < 3
              while reps != 0
                reps -= 1
                w.write_bits(CODE_LENGTH_DEPTH[value], CODE_LENGTH_BITS[value])
              end
            else
              reps -= 3
              w.write_bits(NON_ZERO_REPS_DEPTH[reps], NON_ZERO_REPS_BITS[reps])
            end
            previous_value = value
          end
        end
      end
    end

    # brotli_bit_stream.c:30
    MAX_SIMPLE_DISTANCE_ALPHABET_SIZE = 140

    # Scratch for the fast/trivial metablock storage (C: MetablockArena).
    class MetablockArena
      property lit_histo : Slice(UInt32)
      property cmd_histo : Slice(UInt32)
      property dist_histo : Slice(UInt32)
      property lit_depth : Bytes
      property lit_bits : Slice(UInt16)
      property cmd_depth : Bytes
      property cmd_bits : Slice(UInt16)
      property dist_depth : Bytes
      property dist_bits : Slice(UInt16)
      property tree : Slice(HuffmanTree)

      def initialize
        @lit_histo = Slice(UInt32).new(Brotli::NUM_LITERAL_SYMBOLS)
        @cmd_histo = Slice(UInt32).new(Brotli::NUM_COMMAND_SYMBOLS)
        @dist_histo = Slice(UInt32).new(MAX_SIMPLE_DISTANCE_ALPHABET_SIZE)
        @lit_depth = Bytes.new(Brotli::NUM_LITERAL_SYMBOLS)
        @lit_bits = Slice(UInt16).new(Brotli::NUM_LITERAL_SYMBOLS)
        @cmd_depth = Bytes.new(Brotli::NUM_COMMAND_SYMBOLS)
        @cmd_bits = Slice(UInt16).new(Brotli::NUM_COMMAND_SYMBOLS)
        @dist_depth = Bytes.new(MAX_SIMPLE_DISTANCE_ALPHABET_SIZE)
        @dist_bits = Slice(UInt16).new(MAX_SIMPLE_DISTANCE_ALPHABET_SIZE)
        @tree = Slice(HuffmanTree).new(2 * Brotli::NUM_COMMAND_SYMBOLS + 1) do |i|
          HuffmanTree.new
        end
      end
    end

    # brotli_bit_stream.c:70 — REQUIRES 0 < length <= 1 << 24.
    private def self.encode_mlen(length : Int32) : {UInt64, Int32, UInt64}
      lg = length == 1 ? 1 : log2_floor_non_zero(length - 1) + 1
      mnibbles = (lg < 16 ? 16 : lg + 3) // 4
      {(length &- 1).to_u64, mnibbles * 4, (mnibbles &- 4).to_u64}
    end

    # brotli_bit_stream.c:82
    private def self.store_command_extra(cmd : Command, w : BitWriter) : Nil
      copylen_code = cmd.copy_len_code
      inscode = Enc.insert_length_code(cmd.insert_len.to_i32!)
      copycode = Enc.copy_length_code(copylen_code.to_i32!)
      insnumextra = Enc.insert_extra(inscode.to_i32)
      insextraval = cmd.insert_len.to_u64! &-
                    Enc.insert_base(inscode.to_i32).to_u64!
      copyextraval = copylen_code.to_u64! &-
                     Enc.copy_base(copycode.to_i32).to_u64!
      bits = (copyextraval << insnumextra) | insextraval
      w.write_bits(insnumextra + Enc.copy_extra(copycode.to_i32), bits)
    end

    # brotli_bit_stream.c:120 — compressed metablock header.
    private def self.store_compressed_meta_block_header(
        is_final_block : Bool, length : Int32, w : BitWriter) : Nil
      w.write_bits(1, is_final_block ? 1 : 0) # ISLAST
      w.write_bits(1, 0) if is_final_block    # ISEMPTY
      lenbits, nlenbits, nibblesbits = encode_mlen(length)
      w.write_bits(2, nibblesbits)
      w.write_bits(nlenbits, lenbits)
      w.write_bits(1, 0) unless is_final_block # ISUNCOMPRESSED
    end

    # brotli_bit_stream.c:148 — uncompressed metablock header.
    def self.store_uncompressed_meta_block_header(length : Int32,
                                                  w : BitWriter) : Nil
      w.write_bits(1, 0) # ISLAST (uncompressed can never be last)
      lenbits, nlenbits, nibblesbits = encode_mlen(length)
      w.write_bits(2, nibblesbits)
      w.write_bits(nlenbits, lenbits)
      w.write_bits(1, 1) # ISUNCOMPRESSED
    end

    def self.jump_to_byte_boundary(w : BitWriter) : Nil
      w.pos = (w.pos &+ 7) & ~7
      w.storage[w.pos >> 3] = 0
    end

    # brotli_bit_stream.c:242
    private def self.store_simple_huffman_tree(depths : Bytes,
                                               symbols : StaticArray(Int32, 4),
                                               num_symbols : Int32,
                                               max_bits : Int32,
                                               w : BitWriter) : Nil
      w.write_bits(2, 1)                 # simple Huffman code
      w.write_bits(2, num_symbols - 1)   # NSYM - 1
      i = 0
      while i < num_symbols
        j = i + 1
        while j < num_symbols
          if depths.unsafe_fetch(symbols[j]) < depths.unsafe_fetch(symbols[i])
            symbols[j], symbols[i] = symbols[i], symbols[j]
          end
          j += 1
        end
        i += 1
      end
      i = 0
      while i < num_symbols
        w.write_bits(max_bits, symbols[i].to_u64)
        i += 1
      end
      # tree-select
      if num_symbols == 4
        w.write_bits(1, depths.unsafe_fetch(symbols[0]) == 1 ? 1 : 0)
      end
    end

    # brotli_bit_stream.c:349 — full (non-fast) tree build + store.
    def self.build_and_store_huffman_tree(histogram : Slice(UInt32),
                                          histogram_length : Int32,
                                          alphabet_size : Int32,
                                          tree : Slice(HuffmanTree),
                                          depth : Bytes,
                                          bits : Slice(UInt16),
                                          w : BitWriter) : Nil
      count = 0
      s4 = StaticArray(Int32, 4).new(0)
      i = 0
      while i < histogram_length
        if histogram.unsafe_fetch(i) != 0
          s4[count] = i if count < 4
          count += 1
          break if count > 4
        end
        i += 1
      end

      max_bits = 0
      max_bits_counter = alphabet_size - 1
      while max_bits_counter != 0
        max_bits_counter >>= 1
        max_bits += 1
      end

      if count <= 1
        w.write_bits(4, 1) # simple code, 1 symbol
        w.write_bits(max_bits, s4[0].to_u64)
        depth[s4[0]] = 0
        bits[s4[0]] = 0
        return
      end

      depth.fill(0, 0, histogram_length)
      create_huffman_tree(histogram, histogram_length, 15, tree, depth)
      convert_bit_depths_to_symbols(depth, histogram_length, bits)

      if count <= 4
        store_simple_huffman_tree(depth, s4, count, max_bits, w)
      else
        store_huffman_tree(depth, histogram_length, tree, w)
      end
    end

    # brotli_bit_stream.c:1116
    private def self.build_histograms(data : Bytes, start_pos : Int32,
                                      mask : Int32, commands : Array(Command),
                                      lit_histo : Slice(UInt32),
                                      cmd_histo : Slice(UInt32),
                                      dist_histo : Slice(UInt32)) : Nil
      pos = start_pos
      commands.each do |cmd|
        cmd_histo[cmd.cmd_prefix] &+= 1
        j = cmd.insert_len
        while j != 0
          lit_histo[data.unsafe_fetch(pos & mask)] &+= 1
          pos &+= 1
          j &-= 1
        end
        pos &+= cmd.copy_len
        if cmd.copy_len != 0 && cmd.cmd_prefix >= 128
          dist_histo[cmd.dist_prefix & 0x3FF] &+= 1
        end
      end
    end

    # brotli_bit_stream.c:1141
    private def self.store_data_with_huffman_codes(
        data : Bytes, start_pos : Int32, mask : Int32,
        commands : Array(Command), lit_depth : Bytes,
        lit_bits : Slice(UInt16), cmd_depth : Bytes,
        cmd_bits : Slice(UInt16), dist_depth : Bytes,
        dist_bits : Slice(UInt16), w : BitWriter) : Nil
      pos = start_pos
      commands.each do |cmd|
        cmd_code = cmd.cmd_prefix
        w.write_bits(cmd_depth[cmd_code], cmd_bits[cmd_code].to_u64)
        store_command_extra(cmd, w)
        j = cmd.insert_len
        while j != 0
          lit = data.unsafe_fetch(pos & mask)
          w.write_bits(lit_depth[lit], lit_bits[lit].to_u64)
          pos &+= 1
          j &-= 1
        end
        pos &+= cmd.copy_len
        if cmd.copy_len != 0 && cmd.cmd_prefix >= 128
          dist_code = cmd.dist_prefix & 0x3FF
          distnumextra = cmd.dist_prefix >> 10
          w.write_bits(dist_depth[dist_code], dist_bits[dist_code].to_u64)
          w.write_bits(distnumextra, cmd.dist_extra.to_u64)
        end
      end
    end

    # brotli_bit_stream.c:1196 — quality 3 storage: one tree per alphabet.
    def self.store_meta_block_trivial(s : MetablockArena, data : Bytes,
                                      start_pos : Int32, length : Int32,
                                      mask : Int32, is_last : Bool,
                                      num_distance_symbols : Int32,
                                      commands : Array(Command),
                                      w : BitWriter) : Nil
      store_compressed_meta_block_header(is_last, length, w)
      s.lit_histo.fill(0)
      s.cmd_histo.fill(0)
      s.dist_histo.fill(0)
      build_histograms(data, start_pos, mask, commands, s.lit_histo,
                       s.cmd_histo, s.dist_histo)
      w.write_bits(13, 0)
      build_and_store_huffman_tree(s.lit_histo, Brotli::NUM_LITERAL_SYMBOLS,
                                   Brotli::NUM_LITERAL_SYMBOLS, s.tree,
                                   s.lit_depth, s.lit_bits, w)
      build_and_store_huffman_tree(s.cmd_histo, Brotli::NUM_COMMAND_SYMBOLS,
                                   Brotli::NUM_COMMAND_SYMBOLS, s.tree,
                                   s.cmd_depth, s.cmd_bits, w)
      build_and_store_huffman_tree(s.dist_histo,
                                   MAX_SIMPLE_DISTANCE_ALPHABET_SIZE,
                                   num_distance_symbols, s.tree,
                                   s.dist_depth, s.dist_bits, w)
      store_data_with_huffman_codes(data, start_pos, mask, commands,
                                    s.lit_depth, s.lit_bits, s.cmd_depth,
                                    s.cmd_bits, s.dist_depth, s.dist_bits, w)
      jump_to_byte_boundary(w) if is_last
    end

    # entropy_encode_static.h:524/538
    def self.store_static_command_huffman_tree(w : BitWriter) : Nil
      w.write_bits(56, 0x92624416307003_u64)
      w.write_bits(3, 0)
    end

    def self.store_static_distance_huffman_tree(w : BitWriter) : Nil
      w.write_bits(28, 0x0369DC03_u64)
    end

    # brotli_bit_stream.c:1240 — quality <= 2 storage.
    def self.store_meta_block_fast(s : MetablockArena, data : Bytes,
                                   start_pos : Int32, length : Int32,
                                   mask : Int32, is_last : Bool,
                                   params : Params,
                                   commands : Array(Command),
                                   w : BitWriter) : Nil
      num_distance_symbols = params.dist.alphabet_size_max.to_i32
      distance_alphabet_bits =
        log2_floor_non_zero(num_distance_symbols - 1) + 1

      store_compressed_meta_block_header(is_last, length, w)
      w.write_bits(13, 0)

      if commands.size <= 128
        histogram = Slice(UInt32).new(Brotli::NUM_LITERAL_SYMBOLS)
        pos = start_pos
        num_literals = 0_u64
        commands.each do |cmd|
          j = cmd.insert_len
          while j != 0
            histogram[data.unsafe_fetch(pos & mask)] &+= 1
            pos &+= 1
            j &-= 1
          end
          num_literals &+= cmd.insert_len
          pos &+= cmd.copy_len
        end
        build_and_store_huffman_tree_fast(s.tree, histogram, num_literals, 8,
                                          s.lit_depth, s.lit_bits, w)
        store_static_command_huffman_tree(w)
        store_static_distance_huffman_tree(w)
        store_data_with_huffman_codes(data, start_pos, mask, commands,
                                      s.lit_depth, s.lit_bits,
                                      STATIC_COMMAND_CODE_DEPTH,
                                      STATIC_COMMAND_CODE_BITS,
                                      STATIC_DISTANCE_CODE_DEPTH,
                                      STATIC_DISTANCE_CODE_BITS, w)
      else
        s.lit_histo.fill(0)
        s.cmd_histo.fill(0)
        s.dist_histo.fill(0)
        build_histograms(data, start_pos, mask, commands, s.lit_histo,
                         s.cmd_histo, s.dist_histo)
        build_and_store_huffman_tree_fast(s.tree, s.lit_histo,
                                          histogram_total(s.lit_histo), 8,
                                          s.lit_depth, s.lit_bits, w)
        build_and_store_huffman_tree_fast(s.tree, s.cmd_histo,
                                          histogram_total(s.cmd_histo), 10,
                                          s.cmd_depth, s.cmd_bits, w)
        build_and_store_huffman_tree_fast(s.tree, s.dist_histo,
                                          histogram_total(s.dist_histo),
                                          distance_alphabet_bits,
                                          s.dist_depth, s.dist_bits, w)
        store_data_with_huffman_codes(data, start_pos, mask, commands,
                                      s.lit_depth, s.lit_bits, s.cmd_depth,
                                      s.cmd_bits, s.dist_depth, s.dist_bits, w)
      end
      jump_to_byte_boundary(w) if is_last
    end

    private def self.histogram_total(h : Slice(UInt32)) : UInt64
      t = 0_u64
      h.each { |c| t &+= c }
      t
    end

    # brotli_bit_stream.c:1321 — raw byte storage (uncompressed escape).
    def self.store_uncompressed_meta_block(is_final_block : Bool,
                                           data : Bytes, position : Int32,
                                           mask : Int32, len : Int32,
                                           w : BitWriter) : Nil
      masked_pos = position & mask
      store_uncompressed_meta_block_header(len, w)
      jump_to_byte_boundary(w)

      if masked_pos &+ len > mask &+ 1
        len1 = mask &+ 1 &- masked_pos
        w.storage[w.pos >> 3, len1].copy_from(data[masked_pos, len1])
        w.pos &+= len1 << 3
        len &-= len1
        masked_pos = 0
      end
      w.storage[w.pos >> 3, len].copy_from(data[masked_pos, len])
      w.pos &+= len << 3
      # We need to clear the next bytes to stay compatible with write_bits.
      w.storage[w.pos >> 3] = 0

      # The uncompressed block may not be final; add an empty one after it.
      if is_final_block
        w.write_bits(1, 1) # islast
        w.write_bits(1, 1) # isempty
        jump_to_byte_boundary(w)
      end
    end

    # ------------------------------------------------------------------
    # q4+ pipeline (brotli_bit_stream.c: block switches, context maps,
    # BlockEncoder, StoreMetaBlock). Base64 histogram specials are E6.

    # brotli_bit_stream.c:34
    private def self.block_length_prefix_code(len : Int32) : Int32
      code = len >= 177 ? (len >= 753 ? 20 : 14) : (len >= 41 ? 7 : 0)
      while code < Brotli::NUM_BLOCK_LEN_SYMBOLS - 1 &&
            len >= Brotli::PREFIX_CODE_RANGES[code + 1][0]
        code += 1
      end
      code
    end

    # brotli_bit_stream.c:41
    private def self.get_block_length_prefix_code(len : Int32)
      code = block_length_prefix_code(len)
      {code, Brotli::PREFIX_CODE_RANGES[code][1], len - Brotli::PREFIX_CODE_RANGES[code][0]}
    end

    # brotli_bit_stream.c:48
    class BlockTypeCodeCalculator
      property last_type : Int32
      property second_last_type : Int32

      def initialize
        @last_type = 1
        @second_last_type = 0
      end

      def next_block_type_code(type : Int32) : Int32
        type_code = type == @last_type + 1 ? 1 :
                    type == @second_last_type ? 0 : type + 2
        @second_last_type = @last_type
        @last_type = type
        type_code
      end
    end

    # brotli_bit_stream.c:106 — stores a number between 0 and 255.
    private def self.store_var_len_uint8(n : Int32, w : BitWriter) : Nil
      if n == 0
        w.write_bits(1, 0)
      else
        nbits = log2_floor_non_zero(n)
        w.write_bits(1, 1)
        w.write_bits(3, nbits)
        w.write_bits(nbits, n - (1 << nbits))
      end
    end

    # brotli_bit_stream.c:97
    class BlockSplitCode
      property type_code_calculator : BlockTypeCodeCalculator
      property type_depths : Bytes
      property type_bits : Slice(UInt16)
      property length_depths : Bytes
      property length_bits : Slice(UInt16)

      def initialize
        @type_code_calculator = BlockTypeCodeCalculator.new
        @type_depths = Bytes.new(Brotli::MAX_BLOCK_TYPE_SYMBOLS)
        @type_bits = Slice(UInt16).new(Brotli::MAX_BLOCK_TYPE_SYMBOLS)
        @length_depths = Bytes.new(Brotli::NUM_BLOCK_LEN_SYMBOLS)
        @length_bits = Slice(UInt16).new(Brotli::NUM_BLOCK_LEN_SYMBOLS)
      end
    end

    # brotli_bit_stream.c:737
    def self.store_block_switch(code : BlockSplitCode, block_len : Int32,
                                        block_type : Int32,
                                        is_first_block : Bool,
                                        w : BitWriter) : Nil
      typecode = code.type_code_calculator
                 .next_block_type_code(block_type)
      unless is_first_block
        w.write_bits(code.type_depths[typecode],
                     code.type_bits[typecode].to_u64)
      end
      lencode, len_nextra, len_extra = get_block_length_prefix_code(block_len)
      w.write_bits(code.length_depths[lencode],
                   code.length_bits[lencode].to_u64)
      w.write_bits(len_nextra, len_extra)
    end

    # brotli_bit_stream.c:760
    def self.build_and_store_block_split_code(
        types : Array(UInt8), lengths : Array(UInt32), num_blocks : Int32,
        num_types : Int32, tree : Slice(HuffmanTree), code : BlockSplitCode,
        w : BitWriter) : Nil
      type_histo = Slice(UInt32).new(num_types + 2)
      length_histo = Slice(UInt32).new(Brotli::NUM_BLOCK_LEN_SYMBOLS)
      calculator = code.type_code_calculator
      i = 0
      while i < num_blocks
        type_code = calculator.next_block_type_code(types.unsafe_fetch(i))
        type_histo[type_code] &+= 1 if i != 0
        length_histo[block_length_prefix_code(lengths.unsafe_fetch(i).to_i32)] &+= 1
        i += 1
      end
      store_var_len_uint8(num_types - 1, w)
      if num_types > 1
        build_and_store_huffman_tree(type_histo, num_types + 2, num_types + 2,
                                     tree, code.type_depths, code.type_bits, w)
        build_and_store_huffman_tree(length_histo,
                                     Brotli::NUM_BLOCK_LEN_SYMBOLS,
                                     Brotli::NUM_BLOCK_LEN_SYMBOLS, tree,
                                     code.length_depths, code.length_bits, w)
        store_block_switch(code, lengths.unsafe_fetch(0).to_i32,
                           types.unsafe_fetch(0).to_i32, true, w)
      end
    end

    # brotli_bit_stream.c:794
    private def self.store_trivial_context_map(
        num_types : Int32, context_bits : Int32,
        tree : Slice(HuffmanTree), arena : ContextMapArena,
        w : BitWriter) : Nil
      store_var_len_uint8(num_types - 1, w)
      return if num_types <= 1
      repeat_code = context_bits - 1
      repeat_bits = (1 << repeat_code) - 1
      alphabet_size = num_types + repeat_code
      histogram = arena.histogram
      depths = arena.depths
      bits = arena.bits
      histogram.fill(0_u32, 0, alphabet_size)
      # Write RLEMAX.
      w.write_bits(1, 1)
      w.write_bits(4, repeat_code - 1)
      histogram[repeat_code] = num_types.to_u32!
      histogram[0] = 1_u32
      i = context_bits
      while i < alphabet_size
        histogram[i] = 1_u32
        i += 1
      end
      build_and_store_huffman_tree(histogram, alphabet_size, alphabet_size,
                                   tree, depths, bits, w)
      i = 0
      while i < num_types
        code = i == 0 ? 0 : i + context_bits - 1
        w.write_bits(depths[code], bits[code].to_u64)
        w.write_bits(depths[repeat_code], bits[repeat_code].to_u64)
        w.write_bits(repeat_code, repeat_bits)
        i += 1
      end
      # Write IMTF (inverse-move-to-front) bit.
      w.write_bits(1, 1)
    end

    # brotli_bit_stream.c:575/583/592
    private def self.index_of(v : Bytes, v_size : Int32, value : UInt8) : Int32
      i = 0
      while i < v_size
        return i if v.unsafe_fetch(i) == value
        i += 1
      end
      i
    end

    private def self.move_to_front(v : Bytes, index : Int32) : Nil
      value = v.unsafe_fetch(index)
      i = index
      while i != 0
        v[i] = v.unsafe_fetch(i - 1)
        i -= 1
      end
      v[0] = value
    end

    private def self.move_to_front_transform(v_in : Slice(UInt32),
                                             v_size : Int32,
                                             v_out : Slice(UInt32)) : Nil
      return if v_size == 0
      mtf = Bytes.new(256)
      max_value = v_in.unsafe_fetch(0)
      i = 1
      while i < v_size
        max_value = v_in.unsafe_fetch(i) if v_in.unsafe_fetch(i) > max_value
        i += 1
      end
      i = 0
      while i <= max_value
        mtf[i] = i.to_u8!
        i += 1
      end
      mtf_size = max_value + 1
      i = 0
      while i < v_size
        index = index_of(mtf, mtf_size.to_i32, v_in.unsafe_fetch(i).to_u8!)
        v_out[i] = index.to_u32!
        move_to_front(mtf, index)
        i += 1
      end
    end

    # brotli_bit_stream.c:626
    private def self.run_length_code_zeros(
        in_size : Int32, v : Slice(UInt32),
        max_run_length_prefix : Pointer(Int32)) : Int32
      max_reps = 0_u32
      i = 0
      while i < in_size
        while i < in_size && v.unsafe_fetch(i) != 0
          i += 1
        end
        reps = 0_u32
        while i < in_size && v.unsafe_fetch(i) == 0
          reps &+= 1
          i += 1
        end
        max_reps = Math.max(reps, max_reps)
      end
      max_prefix = max_reps > 0 ? log2_floor_non_zero(max_reps) : 0
      max_prefix = Math.min(max_prefix, max_run_length_prefix.value)
      max_run_length_prefix.value = max_prefix
      out_size = 0
      i = 0
      while i < in_size
        if v.unsafe_fetch(i) != 0
          v[out_size] = v.unsafe_fetch(i) &+ max_prefix.to_u32!
          i += 1
          out_size += 1
        else
          reps = 1_u32
          k = i + 1
          while k < in_size && v.unsafe_fetch(k) == 0
            reps &+= 1
            k += 1
          end
          i += reps
          while reps != 0
            if reps < (2_u32 << max_prefix)
              run_length_prefix = log2_floor_non_zero(reps)
              extra_bits = reps - (1_u32 << run_length_prefix)
              v[out_size] = run_length_prefix.to_u32! &+ (extra_bits << 9)
              out_size += 1
              break
            else
              extra_bits = (1_u32 << max_prefix) - 1
              v[out_size] = max_prefix.to_u32! &+ (extra_bits << 9)
              reps &-= (2_u32 << max_prefix) &- 1
              out_size += 1
            end
          end
        end
      end
      out_size
    end

    # brotli_bit_stream.c:677
    class ContextMapArena
      property histogram : Slice(UInt32)
      property depths : Bytes
      property bits : Slice(UInt16)

      def initialize
        @histogram = Slice(UInt32).new(Brotli::MAX_CONTEXT_MAP_SYMBOLS)
        @depths = Bytes.new(Brotli::MAX_CONTEXT_MAP_SYMBOLS)
        @bits = Slice(UInt16).new(Brotli::MAX_CONTEXT_MAP_SYMBOLS)
      end
    end

    private SYMBOL_BITS = 9

    # brotli_bit_stream.c:683
    private def self.encode_context_map(arena : ContextMapArena,
                                        context_map : Slice(UInt32),
                                        context_map_size : Int32,
                                        num_clusters : Int32,
                                        tree : Slice(HuffmanTree),
                                        w : BitWriter) : Nil
      store_var_len_uint8(num_clusters - 1, w)
      return if num_clusters == 1

      rle_symbols = Slice(UInt32).new(context_map_size)
      move_to_front_transform(context_map, context_map_size, rle_symbols)
      mrlp = Pointer(Int32).malloc(1, 6)
      num_rle_symbols = run_length_code_zeros(context_map_size, rle_symbols,
                                              mrlp)
      max_run_length_prefix = mrlp.value
      symbol_mask = (1_u32 << SYMBOL_BITS) - 1
      histogram = arena.histogram
      histogram.fill(0)
      i = 0
      while i < num_rle_symbols
        histogram[rle_symbols.unsafe_fetch(i) & symbol_mask] &+= 1
        i += 1
      end
      use_rle = max_run_length_prefix > 0
      w.write_bits(1, use_rle ? 1 : 0)
      w.write_bits(4, max_run_length_prefix - 1) if use_rle
      build_and_store_huffman_tree(
        histogram, num_clusters + max_run_length_prefix,
        num_clusters + max_run_length_prefix, tree, arena.depths,
        arena.bits, w)
      i = 0
      while i < num_rle_symbols
        rle_symbol = rle_symbols.unsafe_fetch(i) & symbol_mask
        extra_bits_val = rle_symbols.unsafe_fetch(i) >> SYMBOL_BITS
        w.write_bits(arena.depths[rle_symbol],
                     arena.bits[rle_symbol].to_u64)
        if rle_symbol > 0 && rle_symbol <= max_run_length_prefix
          w.write_bits(rle_symbol, extra_bits_val)
        end
        i += 1
      end
      w.write_bits(1, 1) # use move-to-front
    end

    # brotli_bit_stream.c:832
    class BlockEncoder
      property histogram_length : Int32
      property num_block_types : Int32
      property block_types : Array(UInt8)
      property block_lengths : Array(UInt32)
      property num_blocks : Int32
      property block_split_code : BlockSplitCode
      property block_ix : Int32
      property block_len : Int32
      property entropy_ix : Int32
      property depths : Bytes
      property bits : Slice(UInt16)

      def initialize(@histogram_length, @num_block_types,
                     @block_types, @block_lengths, @num_blocks)
        @block_split_code = BlockSplitCode.new
        @block_ix = 0
        @block_len = @num_blocks == 0 ? 0 : @block_lengths[0].to_i32
        @entropy_ix = 0
        @depths = Bytes.new(0)
        @bits = Slice(UInt16).new(0)
      end

      # brotli_bit_stream.c:870
      def build_and_store_block_switch_entropy_codes(tree : Slice(HuffmanTree),
                                                     w : BitWriter) : Nil
        Enc.build_and_store_block_split_code(@block_types, @block_lengths,
                                              @num_blocks, @num_block_types,
                                              tree, @block_split_code, w)
      end

      # block_encoder_inc.h:8 (base64 histogram specials not ported).
      def build_and_store_entropy_codes(histograms : Array(Histogram),
                                        alphabet_size : Int32,
                                        tree : Slice(HuffmanTree),
                                        w : BitWriter) : Nil
        table_size = histograms.size * @histogram_length
        @depths = Bytes.new(table_size)
        @bits = Slice(UInt16).new(table_size)
        histograms.each_with_index do |h, i|
          ix = i * @histogram_length
          Enc.build_and_store_huffman_tree(h.data, @histogram_length,
                                           alphabet_size, tree,
                                           @depths + ix, @bits + ix, w)
        end
      end

      # brotli_bit_stream.c:879
      def store_symbol(symbol : Int32, w : BitWriter) : Nil
        if @block_len == 0
          @block_ix += 1
          block_ix = @block_ix
          block_len = @block_lengths[block_ix].to_i32
          block_type = @block_types[block_ix].to_i32
          @block_len = block_len
          @entropy_ix = block_type * @histogram_length
          Enc.store_block_switch(@block_split_code, block_len, block_type,
                                 false, w)
        end
        @block_len -= 1
        ix = @entropy_ix + symbol
        w.write_bits(@depths[ix], @bits[ix].to_u64)
      end

      # brotli_bit_stream.c:900
      def store_symbol_with_context(symbol : Int32, context : Int32,
                                    context_map : Slice(UInt32),
                                    context_bits : Int32,
                                    w : BitWriter) : Nil
        if @block_len == 0
          @block_ix += 1
          block_ix = @block_ix
          block_len = @block_lengths[block_ix].to_i32
          block_type = @block_types[block_ix].to_i32
          @block_len = block_len
          @entropy_ix = block_type << context_bits
          Enc.store_block_switch(@block_split_code, block_len, block_type,
                                 false, w)
        end
        @block_len -= 1
        histo_ix = context_map[@entropy_ix + context]
        ix = histo_ix * @histogram_length + symbol
        w.write_bits(@depths[ix], @bits[ix].to_u64)
      end
    end

    # brotli_bit_stream.c:947 — BrotliStoreMetaBlock.
    def self.store_meta_block(arena : MetablockArena,
                              context_map_arena : ContextMapArena,
                              input : Bytes, start_pos : Int32,
                              length : Int32, mask : Int32,
                              prev_byte : UInt8, prev_byte2 : UInt8,
                              is_last : Bool, params : Params,
                              literal_context_mode : Int32,
                              commands : Array(Command),
                              mb : MetaBlockSplit, w : BitWriter) : Nil
      pos = start_pos
      num_distance_symbols = params.dist.alphabet_size_max.to_i32
      num_effective_distance_symbols = params.dist.alphabet_size_limit.to_i32
      tree = arena.tree

      store_compressed_meta_block_header(is_last, length, w)

      literal_enc = BlockEncoder.new(Brotli::NUM_LITERAL_SYMBOLS,
                                     mb.literal_split.num_types,
                                     mb.literal_split.types,
                                     mb.literal_split.lengths,
                                     mb.literal_split.num_blocks)
      command_enc = BlockEncoder.new(Brotli::NUM_COMMAND_SYMBOLS,
                                     mb.command_split.num_types,
                                     mb.command_split.types,
                                     mb.command_split.lengths,
                                     mb.command_split.num_blocks)
      distance_enc = BlockEncoder.new(num_effective_distance_symbols,
                                      mb.distance_split.num_types,
                                      mb.distance_split.types,
                                      mb.distance_split.lengths,
                                      mb.distance_split.num_blocks)

      literal_enc.build_and_store_block_switch_entropy_codes(tree, w)
      command_enc.build_and_store_block_switch_entropy_codes(tree, w)
      distance_enc.build_and_store_block_switch_entropy_codes(tree, w)

      w.write_bits(2, params.dist.distance_postfix_bits)
      w.write_bits(4, params.dist.num_direct_distance_codes >>
                   params.dist.distance_postfix_bits)
      mb.literal_split.num_types.times do
        w.write_bits(2, literal_context_mode)
      end

      if (lcmap = mb.literal_context_map)
        encode_context_map(context_map_arena, lcmap, lcmap.size,
                           mb.literal_histograms.size, tree, w)
      else
        store_trivial_context_map(mb.literal_histograms.size,
                                  Brotli::LITERAL_CONTEXT_BITS, tree,
                                  context_map_arena, w)
      end

      if (dcmap = mb.distance_context_map)
        encode_context_map(context_map_arena, dcmap, dcmap.size,
                           mb.distance_histograms.size, tree, w)
      else
        store_trivial_context_map(mb.distance_histograms.size,
                                  Brotli::DISTANCE_CONTEXT_BITS, tree,
                                  context_map_arena, w)
      end

      literal_enc.build_and_store_entropy_codes(mb.literal_histograms,
                                                Brotli::NUM_LITERAL_SYMBOLS,
                                                tree, w)
      command_enc.build_and_store_entropy_codes(mb.command_histograms,
                                                Brotli::NUM_COMMAND_SYMBOLS,
                                                tree, w)
      distance_enc.build_and_store_entropy_codes(mb.distance_histograms,
                                                 num_distance_symbols, tree, w)

      commands.each do |cmd|
        command_enc.store_symbol(cmd.cmd_prefix, w)
        store_command_extra(cmd, w)
        if (lcmap = mb.literal_context_map)
          j = cmd.insert_len
          while j != 0
            context = CONTEXT_LOOKUP.unsafe_fetch(
              ((literal_context_mode & 3) << 9) | prev_byte).to_i32 |
              CONTEXT_LOOKUP.unsafe_fetch(
                ((literal_context_mode & 3) << 9) | 256 | prev_byte2).to_i32
            literal = input.unsafe_fetch(pos & mask)
            literal_enc.store_symbol_with_context(literal, context, lcmap,
                                                  Brotli::LITERAL_CONTEXT_BITS,
                                                  w)
            prev_byte2 = prev_byte
            prev_byte = literal
            pos += 1
            j -= 1
          end
        else
          j = cmd.insert_len
          while j != 0
            literal_enc.store_symbol(input.unsafe_fetch(pos & mask), w)
            pos += 1
            j -= 1
          end
        end
        pos += cmd.copy_len
        if cmd.copy_len != 0
          prev_byte2 = input.unsafe_fetch((pos - 2) & mask)
          prev_byte = input.unsafe_fetch((pos - 1) & mask)
          if cmd.cmd_prefix >= 128
            dist_code = (cmd.dist_prefix & 0x3FF).to_i32
            distnumextra = cmd.dist_prefix >> 10
            if (dcmap = mb.distance_context_map)
              context = cmd.distance_context.to_i32
              distance_enc.store_symbol_with_context(
                dist_code, context, dcmap, Brotli::DISTANCE_CONTEXT_BITS, w)
            else
              distance_enc.store_symbol(dist_code, w)
            end
            w.write_bits(distnumextra, cmd.dist_extra)
          end
        end
      end
      jump_to_byte_boundary(w) if is_last
    end
  end
end
