# Port of c/enc/block_splitter.{c,h} + block_splitter_inc.h.
# Upstream: 42a2ed4.
#
# The C template over literal/command/distance alphabets collapses to one
# implementation parameterized by alphabet size (data is unified as
# Slice(UInt16); literal bytes are widened by the caller).

module Brotli
  module Enc
    # block_splitter.h:20
    class BlockSplit
      property types : Array(UInt8)
      property lengths : Array(UInt32)
      property num_types : Int32
      property num_blocks : Int32

      def initialize
        @types = Array(UInt8).new
        @lengths = Array(UInt32).new
        @num_types = 0
        @num_blocks = 0
      end
    end

    private MAX_LITERAL_HISTOGRAMS        = 100
    private MAX_COMMAND_HISTOGRAMS        = 50
    private LITERAL_BLOCK_SWITCH_COST     = 28.1
    private COMMAND_BLOCK_SWITCH_COST     = 13.5
    private DISTANCE_BLOCK_SWITCH_COST    = 14.6
    private LITERAL_STRIDE_LENGTH         = 70
    private COMMAND_STRIDE_LENGTH         = 40
    private DISTANCE_STRIDE_LENGTH        = 40
    private SYMBOLS_PER_LITERAL_HISTOGRAM = 544
    private SYMBOLS_PER_COMMAND_HISTOGRAM = 530
    private SYMBOLS_PER_DISTANCE_HISTOGRAM = 544
    private MIN_LENGTH_FOR_BLOCK_SPLITTING = 128
    private ITER_MUL_FOR_REFINING         = 2
    private MIN_ITERS_FOR_REFINING        = 100
    private HISTOGRAMS_PER_BATCH          = 64
    private CLUSTERS_PER_BATCH            = 16

    # block_splitter.c:75 — initial seed should be 7.
    private def self.my_rand(seed : Pointer(UInt32)) : UInt32
      seed.value = seed.value &* 16807_u32
      seed.value
    end

    # block_splitter.c:81
    private def self.bit_cost(count : Int) : Float64
      count == 0 ? -2.0 : fast_log2(count)
    end

    private def self.clear_histograms(histograms : Array(Histogram),
                                      num : Int32) : Nil
      i = 0
      while i < num
        histograms[i].clear
        i += 1
      end
    end

    private def self.histogram_add_vector(histogram : Histogram,
                                          data : Slice(UInt16), pos : Int32,
                                          n : Int32) : Nil
      histogram.total_count &+= n
      i = 0
      while i < n
        histogram.data[data.unsafe_fetch(pos + i)] &+= 1
        i += 1
      end
    end

    # block_splitter_inc.h:12
    private def self.initial_entropy_codes(data : Slice(UInt16),
                                           length : Int32, stride : Int32,
                                           num_histograms : Int32,
                                           histograms : Array(Histogram)) : Nil
      seed = Pointer(UInt32).malloc(1, 7_u32)
      block_length = length // num_histograms
      clear_histograms(histograms, num_histograms)
      i = 0
      while i < num_histograms
        pos = length * i // num_histograms
        if i != 0
          pos += (my_rand(seed) % block_length).to_i32
        end
        pos = length - stride - 1 if pos + stride >= length
        histogram_add_vector(histograms[i], data, pos, stride)
        i += 1
      end
    end

    # block_splitter_inc.h:32
    private def self.random_sample(seed : Pointer(UInt32),
                                   data : Slice(UInt16), length : Int32,
                                   stride : Int32,
                                   sample : Histogram) : Nil
      pos = 0
      if stride >= length
        stride = length
      else
        pos = (my_rand(seed) % (length - stride + 1)).to_i32
      end
      histogram_add_vector(sample, data, pos, stride)
    end

    # block_splitter_inc.h:46
    private def self.refine_entropy_codes(data : Slice(UInt16),
                                          length : Int32, stride : Int32,
                                          num_histograms : Int32,
                                          histograms : Array(Histogram),
                                          tmp : Histogram) : Nil
      iters = ITER_MUL_FOR_REFINING * length // stride + MIN_ITERS_FOR_REFINING
      seed = Pointer(UInt32).malloc(1, 7_u32)
      iters = ((iters + num_histograms - 1) // num_histograms) * num_histograms
      iter = 0
      while iter < iters
        tmp.clear
        random_sample(seed, data, length, stride, tmp)
        histograms[iter % num_histograms].add_histogram(tmp)
        iter += 1
      end
    end

    # block_splitter_inc.h:66 — assigns a block id per data element; returns
    # the number of blocks.
    private def self.find_blocks(data : Slice(UInt16), length : Int32,
                                 block_switch_bitcost : Float64,
                                 num_histograms : Int32,
                                 histograms : Array(Histogram),
                                 insert_cost : Slice(Float64),
                                 cost : Slice(Float64),
                                 switch_signal : Slice(UInt8),
                                 block_id : Slice(UInt8)) : Int32
      alphabet_size = histograms[0].data_size
      bitmap_len = (num_histograms + 7) >> 3
      num_blocks = 1

      # Trivial case: single histogram -> single block type.
      if num_histograms <= 1
        length.times { |i| block_id[i] = 0_u8 }
        return 1
      end

      # Bitcost per symbol per histogram.
      insert_cost.fill(0.0, 0, alphabet_size * num_histograms)
      i = 0
      while i < num_histograms
        insert_cost[i] = fast_log2(histograms[i].total_count)
        i += 1
      end
      i = alphabet_size
      while i != 0
        i -= 1
        j = 0
        while j < num_histograms
          insert_cost[i * num_histograms + j] =
            insert_cost[j] - bit_cost(histograms[j].data.unsafe_fetch(i))
          j += 1
        end
      end

      cost.fill(0.0, 0, num_histograms)
      switch_signal.fill(0_u8, 0, length * bitmap_len)
      prologue_length = 2000
      multiplier = 0.07 / 2000
      byte_ix = 0
      while byte_ix < length
        ix = byte_ix * bitmap_len
        symbol = data.unsafe_fetch(byte_ix)
        insert_cost_ix = symbol.to_i32 * num_histograms
        min_cost = 1e99
        block_switch_cost = block_switch_bitcost
        k = 0
        while k < num_histograms
          cost[k] += insert_cost[insert_cost_ix + k]
          if cost[k] < min_cost
            min_cost = cost[k]
            block_id[byte_ix] = k.to_u8!
          end
          k += 1
        end
        # More blocks for the beginning.
        if byte_ix < prologue_length
          block_switch_cost *= 0.77 + multiplier * byte_ix
        end
        k = 0
        while k < num_histograms
          cost[k] -= min_cost
          if cost[k] >= block_switch_cost
            mask = (1_u8 << (k & 7))
            cost[k] = block_switch_cost
            switch_signal[ix + (k >> 3)] |= mask
          end
          k += 1
        end
        byte_ix += 1
      end

      # Trace back from the last position and switch at the marked places.
      byte_ix = length - 1
      ix = byte_ix * bitmap_len
      cur_id = block_id[byte_ix]
      while byte_ix > 0
        mask = (1_u8 << (cur_id & 7))
        byte_ix -= 1
        ix -= bitmap_len
        if (switch_signal[ix + (cur_id >> 3)] & mask) != 0
          if cur_id != block_id[byte_ix]
            cur_id = block_id[byte_ix]
            num_blocks += 1
          end
        end
        block_id[byte_ix] = cur_id
      end
      num_blocks
    end

    # block_splitter_inc.h:168
    private def self.remap_block_ids(block_ids : Slice(UInt8), length : Int32,
                                     new_id : Slice(UInt16),
                                     num_histograms : Int32) : Int32
      k_invalid_id = 256_u16
      next_id = 0_u16
      i = 0
      while i < num_histograms
        new_id[i] = k_invalid_id
        i += 1
      end
      i = 0
      while i < length
        if new_id[block_ids.unsafe_fetch(i)] == k_invalid_id
          new_id[block_ids.unsafe_fetch(i)] = next_id
          next_id &+= 1
        end
        i += 1
      end
      i = 0
      while i < length
        block_ids[i] = new_id[block_ids.unsafe_fetch(i)].to_u8!
        i += 1
      end
      next_id.to_i32
    end

    # block_splitter_inc.h:190
    private def self.build_block_histograms(data : Slice(UInt16),
                                            length : Int32,
                                            block_ids : Slice(UInt8),
                                            num_histograms : Int32,
                                            histograms : Array(Histogram)) : Nil
      clear_histograms(histograms, num_histograms)
      i = 0
      while i < length
        histograms[block_ids.unsafe_fetch(i)].add(data.unsafe_fetch(i))
        i += 1
      end
    end

    # block_splitter_inc.h:203 — clusters the initial partitioning down to
    # a limited number of block types; fills split.
    private def self.cluster_blocks(data : Slice(UInt16), length : Int32,
                                    num_blocks : Int32,
                                    block_ids : Slice(UInt8),
                                    data_size : Int32,
                                    split : BlockSplit) : Nil
      histogram_symbols = Slice(UInt32).new(num_blocks)
      expected_num_clusters = CLUSTERS_PER_BATCH *
        (num_blocks + HISTOGRAMS_PER_BATCH - 1) // HISTOGRAMS_PER_BATCH
      all_histograms = Array(Histogram).new(expected_num_clusters)
      cluster_size = Array(UInt32).new(expected_num_clusters)
      num_clusters = 0
      histograms = Array(Histogram).new(
        Math.min(num_blocks, HISTOGRAMS_PER_BATCH)) do
        Histogram.new(data_size)
      end
      max_num_pairs = HISTOGRAMS_PER_BATCH * HISTOGRAMS_PER_BATCH // 2
      pairs = Slice(HistogramPair).new(max_num_pairs + 1) { HistogramPair.new }
      block_lengths = Slice(UInt32).new(num_blocks, 0_u32)
      tmp = [Histogram.new(data_size), Histogram.new(data_size)]

      # Calculate block lengths (repeating values -> series length).
      block_idx = 0
      i = 0
      while i < length
        block_lengths[block_idx] &+= 1
        if i + 1 == length || block_ids.unsafe_fetch(i) != block_ids.unsafe_fetch(i + 1)
          block_idx += 1
        end
        i += 1
      end

      # Pre-cluster blocks (cluster batches).
      pos = 0
      i = 0
      while i < num_blocks
        num_to_combine = Math.min(num_blocks - i, HISTOGRAMS_PER_BATCH)
        new_clusters = Slice(UInt32).new(num_to_combine)
        symbols = Slice(UInt32).new(num_to_combine)
        sizes = Slice(UInt32).new(num_to_combine, 1_u32)
        j = 0
        while j < num_to_combine
          block_length = block_lengths.unsafe_fetch(i + j)
          histograms[j].clear
          k = 0
          while k < block_length
            histograms[j].add(data.unsafe_fetch(pos))
            pos += 1
            k += 1
          end
          histograms[j].bit_cost = population_cost(histograms[j])
          new_clusters[j] = j.to_u32!
          symbols[j] = j.to_u32!
          j += 1
        end
        num_new_clusters = histogram_combine(
          histograms, tmp[0], sizes, symbols, new_clusters, pairs,
          num_to_combine, num_to_combine, HISTOGRAMS_PER_BATCH, max_num_pairs)
        j = 0
        while j < num_new_clusters
          h = Histogram.new(data_size)
          h.copy_from(histograms[new_clusters.unsafe_fetch(j)])
          all_histograms << h
          cluster_size << sizes.unsafe_fetch(new_clusters.unsafe_fetch(j))
          j += 1
        end
        # remap for histogram_symbols
        remap = Slice(UInt32).new(HISTOGRAMS_PER_BATCH, UInt32::MAX)
        j = 0
        while j < num_new_clusters
          remap[new_clusters.unsafe_fetch(j)] = j.to_u32!
          j += 1
        end
        j = 0
        while j < num_to_combine
          histogram_symbols[i + j] =
            num_clusters.to_u32! &+ remap[symbols.unsafe_fetch(j)]
          j += 1
        end
        num_clusters += num_new_clusters
        i += HISTOGRAMS_PER_BATCH
      end

      # Final clustering.
      max_num_pairs = Math.min(64 * num_clusters,
                               (num_clusters // 2) * num_clusters)
      if max_num_pairs + 1 > pairs.size
        pairs = Slice(HistogramPair).new(max_num_pairs + 1) { HistogramPair.new }
      end
      clusters = Slice(UInt32).new(num_clusters) { |i2| i2.to_u32! }
      cluster_size_slice = cluster_size.to_slice
      num_final_clusters = histogram_combine(
        all_histograms, tmp[0], cluster_size_slice, histogram_symbols,
        clusters, pairs, num_clusters, num_blocks,
        Brotli::MAX_NUMBER_OF_BLOCK_TYPES, max_num_pairs)

      # Assign blocks to final histograms.
      k_invalid_index = UInt32::MAX
      new_index = Slice(UInt32).new(num_clusters, k_invalid_index)
      pos = 0
      next_index = 0_u32
      i = 0
      while i < num_blocks
        tmp[0].clear
        j = 0
        while j < block_lengths.unsafe_fetch(i)
          tmp[0].add(data.unsafe_fetch(pos))
          pos += 1
          j += 1
        end
        # Among equally good histograms prefer last used.
        best_out = i == 0 ? histogram_symbols.unsafe_fetch(0) :
                            histogram_symbols.unsafe_fetch(i - 1)
        best_bits = histogram_bit_cost_distance(tmp[0],
                                                all_histograms[best_out], tmp[1])
        j = 0
        while j < num_final_clusters
          cur_bits = histogram_bit_cost_distance(
            tmp[0], all_histograms[clusters.unsafe_fetch(j)], tmp[1])
          if cur_bits < best_bits
            best_bits = cur_bits
            best_out = clusters.unsafe_fetch(j)
          end
          j += 1
        end
        histogram_symbols[i] = best_out
        if new_index.unsafe_fetch(best_out) == k_invalid_index
          new_index[best_out] = next_index
          next_index &+= 1
        end
        i += 1
      end

      # Rewrite final assignment to the block split.
      cur_length = 0_u32
      block_idx = 0
      max_type = 0_u8
      i = 0
      while i < num_blocks
        cur_length &+= block_lengths.unsafe_fetch(i)
        if i + 1 == num_blocks || histogram_symbols.unsafe_fetch(i) !=
                                  histogram_symbols.unsafe_fetch(i + 1)
          id = new_index.unsafe_fetch(histogram_symbols.unsafe_fetch(i)).to_u8!
          split.types << id
          split.lengths << cur_length
          max_type = Math.max(max_type, id)
          cur_length = 0_u32
          block_idx += 1
        end
        i += 1
      end
      split.num_blocks = block_idx
      split.num_types = max_type.to_i32 + 1
    end

    # The splitter is monomorphic over Histogram; the alphabet size is
    # carried by the symbol array (literals are widened to UInt16).

    # block_splitter_inc.h:403 — SplitByteVector.
    private def self.split_byte_vector(data : Slice(UInt16), length : Int32,
                                       data_size : Int32,
                                       symbols_per_histogram : Int32,
                                       max_histograms : Int32,
                                       sampling_stride_length : Int32,
                                       block_switch_cost : Float64,
                                       quality : Int32,
                                       split : BlockSplit) : Nil
      num_histograms = length // symbols_per_histogram + 1
      num_histograms = max_histograms if num_histograms > max_histograms

      # Corner case: no input.
      if length == 0
        split.num_types = 1
        return
      end

      if length < MIN_LENGTH_FOR_BLOCK_SPLITTING
        split.num_types = 1
        split.types << 0_u8
        split.lengths << length.to_u32!
        split.num_blocks = 1
        return
      end

      histograms = Array(Histogram).new(num_histograms + 1) { Histogram.new(data_size) }
      tmp = histograms[num_histograms]
      initial_entropy_codes(data, length, sampling_stride_length,
                            num_histograms, histograms)
      refine_entropy_codes(data, length, sampling_stride_length,
                           num_histograms, histograms, tmp)

      block_ids = Slice(UInt8).new(length)
      num_blocks = 0
      bitmaplen = (num_histograms + 7) >> 3
      insert_cost = Slice(Float64).new(data_size * num_histograms)
      cost = Slice(Float64).new(num_histograms)
      switch_signal = Slice(UInt8).new(length * bitmaplen)
      new_id = Slice(UInt16).new(num_histograms)
      iters = quality < HQ_ZOPFLIFICATION_QUALITY ? 3 : 10
      iters.times do
        num_blocks = find_blocks(data, length, block_switch_cost,
                                 num_histograms, histograms, insert_cost,
                                 cost, switch_signal, block_ids)
        num_histograms = remap_block_ids(block_ids, length, new_id,
                                         num_histograms)
        build_block_histograms(data, length, block_ids, num_histograms,
                               histograms)
      end
      cluster_blocks(data, length, num_blocks, block_ids, data_size, split)
    end

    # block_splitter.c:39
    private def self.count_literals(commands : Array(Command)) : Int32
      total = 0
      commands.each { |cmd| total += cmd.insert_len }
      total
    end

    # block_splitter.c:49
    private def self.copy_literals_to_byte_array(commands : Array(Command),
                                                 data : Bytes, offset : Int32,
                                                 mask : Int32,
                                                 literals : Slice(UInt16)) : Nil
      pos = 0
      from_pos = offset & mask
      commands.each do |cmd|
        insert_len = cmd.insert_len.to_i32
        if from_pos + insert_len > mask
          head_size = mask + 1 - from_pos
          k = 0
          while k < head_size
            literals[pos + k] = data.unsafe_fetch(from_pos + k).to_u16!
            k += 1
          end
          from_pos = 0
          pos += head_size
          insert_len -= head_size
        end
        if insert_len > 0
          k = 0
          while k < insert_len
            literals[pos + k] = data.unsafe_fetch(from_pos + k).to_u16!
            k += 1
          end
          pos += insert_len
        end
        from_pos = (from_pos + insert_len + cmd.copy_len) & mask
      end
    end

    # block_splitter.c:123 — BrotliSplitBlock.
    def self.split_block(commands : Array(Command), data : Bytes,
                         pos : Int32, mask : Int32, quality : Int32,
                         literal_split : BlockSplit,
                         insert_and_copy_split : BlockSplit,
                         dist_split : BlockSplit) : Nil
      # Literals.
      literals_count = count_literals(commands)
      literals = Slice(UInt16).new(literals_count)
      copy_literals_to_byte_array(commands, data, pos, mask, literals)
      split_byte_vector(literals, literals_count, Brotli::NUM_LITERAL_SYMBOLS,
                        SYMBOLS_PER_LITERAL_HISTOGRAM, MAX_LITERAL_HISTOGRAMS,
                        LITERAL_STRIDE_LENGTH, LITERAL_BLOCK_SWITCH_COST,
                        quality, literal_split)

      # Command prefix codes.
      insert_and_copy_codes = Slice(UInt16).new(commands.size) do |i|
        commands[i].cmd_prefix
      end
      split_byte_vector(insert_and_copy_codes, commands.size,
                        Brotli::NUM_COMMAND_SYMBOLS,
                        SYMBOLS_PER_COMMAND_HISTOGRAM, MAX_COMMAND_HISTOGRAMS,
                        COMMAND_STRIDE_LENGTH, COMMAND_BLOCK_SWITCH_COST,
                        quality, insert_and_copy_split)

      # Distance prefix codes.
      distance_prefixes = Slice(UInt16).new(commands.size)
      j = 0
      commands.each do |cmd|
        if cmd.copy_len != 0 && cmd.cmd_prefix >= 128
          distance_prefixes[j] = (cmd.dist_prefix & 0x3FF).to_u16!
          j += 1
        end
      end
      split_byte_vector(distance_prefixes, j,
                        NUM_HISTOGRAM_DISTANCE_SYMBOLS,
                        SYMBOLS_PER_DISTANCE_HISTOGRAM, MAX_COMMAND_HISTOGRAMS,
                        DISTANCE_STRIDE_LENGTH, DISTANCE_BLOCK_SWITCH_COST,
                        quality, dist_split)
    end
  end
end
