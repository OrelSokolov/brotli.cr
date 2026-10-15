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
  end
end
