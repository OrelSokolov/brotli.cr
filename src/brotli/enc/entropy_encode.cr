# Port of c/enc/entropy_encode.{c,h}. Upstream: 42a2ed4.

module Brotli
  module Enc
    # A node of a Huffman tree.
    struct HuffmanTree
      property total_count : UInt32
      property index_left : Int16
      property index_right_or_value : Int16

      def initialize(@total_count : UInt32 = 0_u32, @index_left : Int16 = -1_i16,
                   @index_right_or_value : Int16 = -1_i16)
      end
    end

    K_BROTLI_SHELL_GAPS = [132, 57, 23, 10, 4, 1]

    # entropy_encode.h: SortHuffmanTreeItems — input-size optimized shell
    # sort; the comparator is a total order, so the result is deterministic.
    def self.sort_huffman_tree_items(items : Slice(HuffmanTree), n : Int32,
                                     &comparator : HuffmanTree, HuffmanTree -> Bool) : Nil
      if n < 13
        # Insertion sort.
        i = 1
        while i < n
          tmp = items[i]
          k = i
          j = i - 1
          while comparator.call(tmp, items[j])
            items[k] = items[j]
            k = j
            break if j == 0
            j -= 1
          end
          items[k] = tmp
          i += 1
        end
      else
        # Shell sort.
        g = n < 57 ? 2 : 0
        while g < 6
          gap = K_BROTLI_SHELL_GAPS[g]
          i = gap
          while i < n
            j = i
            tmp = items[i]
            while j >= gap && comparator.call(tmp, items[j - gap])
              items[j] = items[j - gap]
              j -= gap
            end
            items[j] = tmp
            i += 1
          end
          g += 1
        end
      end
    end

    # Returns true if assignment of depths succeeded.
    def self.set_depth(p0 : Int32, pool : Slice(HuffmanTree), depth : Bytes,
                       max_depth : Int32) : Bool
      stack = StaticArray(Int32, 16).new(-1)
      level = 0
      p = p0
      loop do
        if pool[p].index_left >= 0
          level += 1
          return false if level > max_depth
          stack[level] = pool[p].index_right_or_value
          p = pool[p].index_left
          next
        else
          depth[pool[p].index_right_or_value] = level.to_u8!
        end
        while level >= 0 && stack[level] == -1
          level -= 1
        end
        return true if level < 0
        p = stack[level]
        stack[level] = -1
      end
    end

    # Creates a Huffman tree limited to tree_limit bits depth from the
    # population counts in data[0, length). depth receives code lengths.
    # tree must have at least 2 * length + 1 entries.
    def self.create_huffman_tree(data : Slice(UInt32), length : Int32,
                                 tree_limit : Int32, tree : Slice(HuffmanTree),
                                 depth : Bytes) : Nil
      count_limit = 1_u32
      loop do
        n = 0
        i = length
        while i != 0
          i -= 1
          if data[i] != 0
            count = data[i] > count_limit ? data[i] : count_limit
            tree[n] = HuffmanTree.new(count, -1_i16, i.to_i16)
            n += 1
          end
        end

        if n == 1
          # Only one element.
          depth[tree[0].index_right_or_value] = 1
          break
        end

        sort_huffman_tree_items(tree, n) do |v0, v1|
          if v0.total_count != v1.total_count
            v0.total_count < v1.total_count
          else
            v0.index_right_or_value > v1.index_right_or_value
          end
        end

        sentinel = HuffmanTree.new(UInt32::MAX, -1_i16, -1_i16)
        tree[n] = sentinel
        tree[n + 1] = sentinel

        i = 0     # Points to the next leaf node.
        j = n + 1 # Points to the next non-leaf node.
        k = n - 1
        while k != 0
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
          j_end = 2 * n - k
          tree[j_end] = HuffmanTree.new(
            tree[left].total_count &+ tree[right].total_count,
            left.to_i16, right.to_i16)

          # Add back the last sentinel node.
          tree[j_end + 1] = sentinel
          k -= 1
        end
        if set_depth(2 * n - 1, tree, depth, tree_limit)
          break
        end
        count_limit = count_limit &* 2
      end
    end

    private def self.reverse_bytes(v : Bytes, start : Int32, end_ : Int32) : Nil
      e = end_ - 1
      s = start
      while s < e
        v[s], v[e] = v[e], v[s]
        s += 1
        e -= 1
      end
    end

    # Writes code-length symbol 16 (repeat previous) runs. Returns the new
    # tree_size; tree/extra_bits_data must have room.
    def self.write_huffman_tree_repetitions(previous_value : UInt8, value : UInt8,
                                            repetitions : Int32, tree_size : Int32,
                                            tree : Bytes,
                                            extra_bits_data : Bytes) : Int32
      size = tree_size
      if previous_value != value
        tree[size] = value
        extra_bits_data[size] = 0
        size += 1
        repetitions -= 1
      end
      if repetitions == 7
        tree[size] = value
        extra_bits_data[size] = 0
        size += 1
        repetitions -= 1
      end
      if repetitions < 3
        repetitions.times do
          tree[size] = value
          extra_bits_data[size] = 0
          size += 1
        end
      else
        start = size
        repetitions -= 3
        loop do
          tree[size] = Brotli::REPEAT_PREVIOUS_CODE_LENGTH.to_u8
          extra_bits_data[size] = (repetitions & 0x3).to_u8
          size += 1
          repetitions >>= 2
          break if repetitions == 0
          repetitions -= 1
        end
        reverse_bytes(tree, start, size)
        reverse_bytes(extra_bits_data, start, size)
      end
      size
    end

    # Writes code-length symbol 17 (repeat zero) runs.
    def self.write_huffman_tree_repetitions_zeros(repetitions : Int32,
                                                  tree_size : Int32, tree : Bytes,
                                                  extra_bits_data : Bytes) : Int32
      size = tree_size
      if repetitions == 11
        tree[size] = 0
        extra_bits_data[size] = 0
        size += 1
        repetitions -= 1
      end
      if repetitions < 3
        repetitions.times do
          tree[size] = 0
          extra_bits_data[size] = 0
          size += 1
        end
      else
        start = size
        repetitions -= 3
        loop do
          tree[size] = Brotli::REPEAT_ZERO_CODE_LENGTH.to_u8
          extra_bits_data[size] = (repetitions & 0x7).to_u8
          size += 1
          repetitions >>= 3
          break if repetitions == 0
          repetitions -= 1
        end
        reverse_bytes(tree, start, size)
        reverse_bytes(extra_bits_data, start, size)
      end
      size
    end

    # Changes population counts so that the consequent Huffman tree
    # compression, especially its RLE part, compresses better.
    # good_for_rle must be at least length bytes (scratch).
    def self.optimize_huffman_counts_for_rle(length : Int32,
                                             counts : Slice(UInt32),
                                             good_for_rle : Bytes) : Nil
      streak_limit = 1240_u64
      nonzero_count = 0
      i = 0
      while i < length
        nonzero_count += 1 if counts[i] != 0
        i += 1
      end
      return if nonzero_count < 16
      while length != 0 && counts[length - 1] == 0
        length -= 1
      end
      return if length == 0 # All zeros.

      # counts[0, length) has no trailing zeros now.
      nonzeros = 0
      smallest_nonzero = 1_u32 << 30
      i = 0
      while i < length
        if counts[i] != 0
          nonzeros += 1
          smallest_nonzero = counts[i] if smallest_nonzero > counts[i]
        end
        i += 1
      end
      if nonzeros < 5
        return # Small histogram will model it well.
      end
      if smallest_nonzero < 4
        zeros = length - nonzeros
        if zeros < 6
          i = 1
          while i < length - 1
            if counts[i - 1] != 0 && counts[i] == 0 && counts[i + 1] != 0
              counts[i] = 1
            end
            i += 1
          end
        end
      end
      return if nonzeros < 28

      # 2) Mark all population counts that already can be encoded
      # with an RLE code: runs of 0's longer than 5, runs of non-0's
      # longer than 7.
      good_for_rle.fill(0, 0, length)
      symbol = counts[0]
      step = 0
      i = 0
      while i <= length
        if i == length || counts[i] != symbol
          if (symbol == 0 && step >= 5) || (symbol != 0 && step >= 7)
            k = 0
            while k < step
              good_for_rle[i - k - 1] = 1
              k += 1
            end
          end
          step = 1
          symbol = counts[i] if i != length
        else
          step += 1
        end
        i += 1
      end

      # 3) Replace population counts that lead to more RLE codes.
      # Math here is in 24.8 fixed point representation.
      stride = 0
      limit = 256_u64 * (counts[0] + counts[1] + counts[2]) // 3 + 420
      sum = 0_u64
      i = 0
      while i <= length
        if i == length || good_for_rle[i] != 0 ||
           (i != 0 && good_for_rle[i - 1] != 0) ||
           (256_u64 * counts[i] &- limit &+ streak_limit) >= 2_u64 &* streak_limit
          if stride >= 4 || (stride >= 3 && sum == 0)
            # The stride must end, collapse what we have, if we have enough.
            count = (sum &+ stride // 2) // stride
            count = 1 if count == 0
            count = 0 if sum == 0 # Don't upgrade an all-zeros stride to ones.
            k = 0
            while k < stride
              # counts[i] belongs to the next stride already, thus - 1.
              counts[i - k - 1] = count.to_u32!
              k += 1
            end
          end
          stride = 0
          sum = 0
          if i < length - 2
            limit = 256_u64 * (counts[i] + counts[i + 1] + counts[i + 2]) // 3 + 420
          elsif i < length
            limit = 256_u64 * counts[i]
          else
            limit = 0
          end
        end
        stride += 1
        if i != length
          sum &+= counts[i]
          limit = (256_u64 &* sum &+ stride // 2) // stride if stride >= 4
          limit &+= 120 if stride == 4
        end
        i += 1
      end
    end

    private def self.decide_over_rle_use(depth : Bytes, length : Int32) : {Bool, Bool}
      total_reps_zero = 0
      total_reps_non_zero = 0
      count_reps_zero = 1
      count_reps_non_zero = 1
      i = 0
      while i < length
        value = depth[i]
        reps = 1
        k = i + 1
        while k < length && depth[k] == value
          reps += 1
          k += 1
        end
        if reps >= 3 && value == 0
          total_reps_zero += reps
          count_reps_zero += 1
        end
        if reps >= 4 && value != 0
          total_reps_non_zero += reps
          count_reps_non_zero += 1
        end
        i += reps
      end
      {total_reps_non_zero > count_reps_non_zero * 2,
       total_reps_zero > count_reps_zero * 2}
    end

    # Serializes code lengths (with RLE for zeros/non-zeros) into
    # (tree, extra_bits_data) symbol/extra-bit streams. Returns tree_size.
    def self.write_huffman_tree(depth : Bytes, length : Int32, tree : Bytes,
                                extra_bits_data : Bytes) : Int32
      previous_value = Brotli::INITIAL_REPEATED_CODE_LENGTH.to_u8
      use_rle_for_non_zero = false
      use_rle_for_zero = false

      # Throw away trailing zeros.
      new_length = length
      i = 0
      while i < length
        break if depth[length - i - 1] != 0
        new_length -= 1
        i += 1
      end

      # First gather statistics on if it is a good idea to do RLE.
      if length > 50
        use_rle_for_non_zero, use_rle_for_zero =
          decide_over_rle_use(depth, new_length)
      end

      # Actual RLE coding.
      tree_size = 0
      i = 0
      while i < new_length
        value = depth[i]
        reps = 1
        if (value != 0 && use_rle_for_non_zero) ||
           (value == 0 && use_rle_for_zero)
          k = i + 1
          while k < new_length && depth[k] == value
            reps += 1
            k += 1
          end
        end
        if value == 0
          tree_size = write_huffman_tree_repetitions_zeros(
            reps, tree_size, tree, extra_bits_data)
        else
          tree_size = write_huffman_tree_repetitions(
            previous_value, value, reps, tree_size, tree, extra_bits_data)
          previous_value = value
        end
        i += reps
      end
      tree_size
    end

    private def self.reverse_bits(num_bits : Int32, bits : UInt16) : UInt16
      lut = {0x00, 0x08, 0x04, 0x0C, 0x02, 0x0A, 0x06, 0x0E,
             0x01, 0x09, 0x05, 0x0D, 0x03, 0x0B, 0x07, 0x0F}
      retval = lut[bits & 0x0F].to_u32
      i = 4
      while i < num_bits
        retval <<= 4
        bits >>= 4
        retval |= lut[bits & 0x0F]
        i += 4
      end
      retval >>= ((0 &- num_bits) & 0x03)
      retval.to_u16!
    end

    MAX_HUFFMAN_BITS = 16

    # Canonical code assignment + bit reversal: fills bits[i] for every
    # symbol with depth[i] != 0.
    def self.convert_bit_depths_to_symbols(depth : Bytes, len : Int32,
                                           bits : Slice(UInt16)) : Nil
      bl_count = StaticArray(UInt16, MAX_HUFFMAN_BITS).new(0_u16)
      next_code = StaticArray(UInt16, MAX_HUFFMAN_BITS).new(0_u16)
      i = 0
      while i < len
        bl_count[depth[i]] &+= 1
        i += 1
      end
      bl_count[0] = 0
      next_code[0] = 0
      code = 0
      i = 1
      while i < MAX_HUFFMAN_BITS
        code = (code &+ bl_count[i - 1]) << 1
        next_code[i] = code.to_u16!
        i += 1
      end
      i = 0
      while i < len
        if depth[i] != 0
          bits[i] = reverse_bits(depth[i], next_code[depth[i]])
          next_code[depth[i]] &+= 1
        end
        i += 1
      end
    end
  end
end
