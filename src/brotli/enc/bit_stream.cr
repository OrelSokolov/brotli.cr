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
  end
end
