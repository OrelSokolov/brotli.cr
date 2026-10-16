# Port of c/enc/metablock.{c,h} + metablock_inc.h (greedy path, q4-q9) and
# the literal-context decision helpers from encode.c. Upstream: 42a2ed4.
# The HQ path (BrotliBuildMetaBlock, distance param re-tuning, base64
# regions) is E6 scope and not ported here.

module Brotli
  module Enc
    MAX_STATIC_CONTEXTS = 13

    # metablock.h:28
    class MetaBlockSplit
      property literal_split : BlockSplit
      property command_split : BlockSplit
      property distance_split : BlockSplit
      property context_modes : Array(Int32)? # per literal block type
      property literal_histograms : Array(Histogram)
      property command_histograms : Array(Histogram)
      property distance_histograms : Array(Histogram)
      property literal_context_map : Slice(UInt32)?
      property distance_context_map : Slice(UInt32)?

      def initialize
        @literal_split = BlockSplit.new
        @command_split = BlockSplit.new
        @distance_split = BlockSplit.new
        @literal_histograms = Array(Histogram).new
        @command_histograms = Array(Histogram).new
        @distance_histograms = Array(Histogram).new
      end
    end

    # metablock_inc.h:14 + metablock.c:463 — greedy block splitter for one
    # category; num_contexts == 1 is the plain BlockSplitter, > 1 the
    # ContextBlockSplitter (both share the same decision logic).
    class BlockSplitter
      @alphabet_size : Int32
      @num_contexts : Int32
      @max_block_types : Int32
      @min_block_size : Int32
      @split_threshold : Float64
      @split : BlockSplit
      @histograms : Array(Histogram)
      @target_block_size : Int32
      @block_size : Int32
      @curr_histogram_ix : Int32
      @last_histogram_ix : StaticArray(Int32, 2)
      @last_entropy : Slice(Float64)
      @merge_last_count : Int32
      @num_blocks : Int32
      @combined_histo : Array(Histogram)

      def initialize(alphabet_size : Int32, num_contexts : Int32,
                     min_block_size : Int32, split_threshold : Float64,
                     num_symbols : Int32, split : BlockSplit,
                     data_size : Int32)
        max_num_blocks = num_symbols // min_block_size + 1
        # One more histogram than the max number of block types for the
        # current histogram when the meta-block is too big.
        if num_contexts == 1
          max_num_types = Math.min(max_num_blocks,
                                   Brotli::MAX_NUMBER_OF_BLOCK_TYPES + 1)
        else
          max_block_types = Brotli::MAX_NUMBER_OF_BLOCK_TYPES // num_contexts
          max_num_types = Math.min(max_num_blocks, max_block_types + 1)
        end
        @alphabet_size = alphabet_size
        @num_contexts = num_contexts
        @max_block_types = num_contexts == 1 ?
          Brotli::MAX_NUMBER_OF_BLOCK_TYPES :
          Brotli::MAX_NUMBER_OF_BLOCK_TYPES // num_contexts
        @min_block_size = min_block_size
        @split_threshold = split_threshold
        @split = split
        @split.types.concat(Array(UInt8).new(max_num_blocks, 0_u8))
        @split.lengths.concat(Array(UInt32).new(max_num_blocks, 0_u32))
        @split.num_blocks = max_num_blocks
        @histograms = Array(Histogram).new(max_num_types * num_contexts) do
          Histogram.new(data_size)
        end
        @target_block_size = min_block_size
        @block_size = 0
        @curr_histogram_ix = 0
        @last_histogram_ix = StaticArray(Int32, 2).new(0)
        @last_entropy = Slice(Float64).new(2 * MAX_STATIC_CONTEXTS)
        @merge_last_count = 0
        @num_blocks = 0
        @combined_histo = Array(Histogram).new(2 * num_contexts) do
          Histogram.new(data_size)
        end
      end

      # metablock_inc.h:87 / metablock.c:543.
      def finish_block(is_final : Bool) : Nil
        split = @split
        num_contexts = @num_contexts
        histograms = @histograms
        @block_size = Math.max(@block_size, @min_block_size)
        if @num_blocks == 0
          # Create first block.
          split.lengths[0] = @block_size.to_u32!
          split.types[0] = 0_u8
          i = 0
          while i < num_contexts
            e = Enc.bits_entropy(histograms[i].data, @alphabet_size)
            @last_entropy[num_contexts + i] = e
            @last_entropy[i] = e
            i += 1
          end
          @num_blocks += 1
          split.num_types += 1
          @curr_histogram_ix += num_contexts
          if @curr_histogram_ix < histograms.size
            clear_histograms(@curr_histogram_ix)
          end
          @block_size = 0
        elsif @block_size > 0
          # Try merging the current histogram set with the last and second
          # last block types; decide on total entropy reduction.
          entropy = StaticArray(Float64, MAX_STATIC_CONTEXTS).new(0.0)
          combined_entropy = Slice(Float64).new(2 * MAX_STATIC_CONTEXTS)
          diff = StaticArray(Float64, 2).new(0.0)
          i = 0
          while i < num_contexts
            curr_histo_ix = @curr_histogram_ix + i
            entropy[i] = Enc.bits_entropy(
              histograms[curr_histo_ix].data, @alphabet_size)
            j = 0
            while j < 2
              jx = j * num_contexts + i
              last_histogram_ix = @last_histogram_ix[j] + i
              @combined_histo[jx].copy_from(histograms[curr_histo_ix])
              @combined_histo[jx].add_histogram(histograms[last_histogram_ix])
              combined_entropy[jx] = Enc.bits_entropy(
                @combined_histo[jx].data, @alphabet_size)
              diff[j] += combined_entropy[jx] - entropy[i] -
                         @last_entropy[jx]
              j += 1
            end
            i += 1
          end

          if split.num_types < @max_block_types &&
             diff[0] > @split_threshold && diff[1] > @split_threshold
            # Create new block.
            split.lengths[@num_blocks] = @block_size.to_u32!
            split.types[@num_blocks] = split.num_types.to_u8!
            @last_histogram_ix[1] = @last_histogram_ix[0]
            @last_histogram_ix[0] = split.num_types * num_contexts
            i = 0
            while i < num_contexts
              @last_entropy[num_contexts + i] = @last_entropy[i]
              @last_entropy[i] = entropy[i]
              i += 1
            end
            @num_blocks += 1
            split.num_types += 1
            @curr_histogram_ix += num_contexts
            if @curr_histogram_ix < histograms.size
              clear_histograms(@curr_histogram_ix)
            end
            @block_size = 0
            @merge_last_count = 0
            @target_block_size = @min_block_size
          elsif diff[1] < diff[0] - 20.0
            # Combine this block with second last block.
            split.lengths[@num_blocks] = @block_size.to_u32!
            split.types[@num_blocks] = split.types[@num_blocks - 2]
            @last_histogram_ix.swap(0, 1)
            i = 0
            while i < num_contexts
              histograms[@last_histogram_ix[0] + i].copy_from(
                @combined_histo[num_contexts + i])
              @last_entropy[num_contexts + i] = @last_entropy[i]
              @last_entropy[i] = combined_entropy[num_contexts + i]
              histograms[@curr_histogram_ix + i].clear
              i += 1
            end
            @num_blocks += 1
            @block_size = 0
            @merge_last_count = 0
            @target_block_size = @min_block_size
          else
            # Combine this block with last block.
            split.lengths[@num_blocks - 1] &+= @block_size
            i = 0
            while i < num_contexts
              histograms[@last_histogram_ix[0] + i].copy_from(
                @combined_histo[i])
              @last_entropy[i] = combined_entropy[i]
              if split.num_types == 1
                @last_entropy[num_contexts + i] = @last_entropy[i]
              end
              histograms[@curr_histogram_ix + i].clear
              i += 1
            end
            @block_size = 0
            @merge_last_count += 1
            if @merge_last_count > 1
              @target_block_size += @min_block_size
            end
          end
        end
        if is_final
          # C: m->histograms_size = num_types * num_contexts.
          used = split.num_types * num_contexts
          while histograms.size > used
            histograms.pop
          end
          split.num_blocks = @num_blocks
        end
      end

      # metablock_inc.h:177 / metablock.c:665.
      def add_symbol(symbol : Int32, context : Int32 = 0) : Nil
        @histograms[@curr_histogram_ix + context].add(symbol)
        @block_size += 1
        if @block_size == @target_block_size
          finish_block(false)
        end
      end

      private def clear_histograms(from : Int32) : Nil
        i = from
        while i < from + @num_contexts
          @histograms[i].clear
          i += 1
        end
      end

      def histograms : Array(Histogram)
        @histograms
      end
    end

    # metablock.c:677
    private def self.map_static_contexts(num_contexts : Int32,
                                         static_context_map : Slice(UInt32),
                                         mb : MetaBlockSplit) : Nil
      size = mb.literal_split.num_types << Brotli::LITERAL_CONTEXT_BITS
      map = Slice(UInt32).new(size)
      i = 0
      while i < mb.literal_split.num_types
        offset = (i * num_contexts).to_u32!
        j = 0
        while j < (1 << Brotli::LITERAL_CONTEXT_BITS)
          map[(i << Brotli::LITERAL_CONTEXT_BITS) + j] =
            offset &+ static_context_map.unsafe_fetch(j)
          j += 1
        end
        i += 1
      end
      mb.literal_context_map = map
    end

    # metablock.c:708 — BrotliBuildMetaBlockGreedyInternal.
    def self.build_meta_block_greedy(ringbuffer : Bytes, pos : Int32,
                                     mask : Int32,
                                     prev_byte : UInt8, prev_byte2 : UInt8,
                                     context_mode : Int32,
                                     num_contexts : Int32,
                                     static_context_map : Slice(UInt32)?,
                                     commands : Array(Command),
                                     mb : MetaBlockSplit) : Nil
      num_literals = 0
      commands.each { |cmd| num_literals += cmd.insert_len }

      lit_blocks = BlockSplitter.new(256, num_contexts, 512, 400.0,
                                     num_literals, mb.literal_split,
                                     Brotli::NUM_LITERAL_SYMBOLS)
      cmd_blocks = BlockSplitter.new(Brotli::NUM_COMMAND_SYMBOLS, 1, 1024,
                                     500.0, commands.size, mb.command_split,
                                     Brotli::NUM_COMMAND_SYMBOLS)
      dist_blocks = BlockSplitter.new(64, 1, 512, 100.0, commands.size,
                                      mb.distance_split, 64)

      i = 0
      while i < commands.size
        cmd = commands.unsafe_fetch(i)
        cmd_blocks.add_symbol(cmd.cmd_prefix)
        j = cmd.insert_len
        while j != 0
          literal = ringbuffer.unsafe_fetch(pos & mask)
          if num_contexts == 1
            lit_blocks.add_symbol(literal)
          else
            ctx = CONTEXT_LOOKUP.unsafe_fetch(
              ((context_mode & 3) << 9) | prev_byte).to_i32 |
              CONTEXT_LOOKUP.unsafe_fetch(
                ((context_mode & 3) << 9) | 256 | prev_byte2).to_i32
            lit_blocks.add_symbol(literal.to_i32,
                                  static_context_map.not_nil![ctx].to_i32)
          end
          prev_byte2 = prev_byte
          prev_byte = literal
          pos += 1
          j -= 1
        end
        pos += cmd.copy_len
        if cmd.copy_len != 0
          prev_byte2 = ringbuffer.unsafe_fetch((pos - 2) & mask)
          prev_byte = ringbuffer.unsafe_fetch((pos - 1) & mask)
          if cmd.cmd_prefix >= 128
            dist_blocks.add_symbol(cmd.dist_prefix & 0x3FF)
          end
        end
        i += 1
      end

      lit_blocks.finish_block(true)
      mb.literal_histograms = lit_blocks.histograms
      cmd_blocks.finish_block(true)
      mb.command_histograms = cmd_blocks.histograms
      dist_blocks.finish_block(true)
      mb.distance_histograms = dist_blocks.histograms

      if num_contexts > 1
        map_static_contexts(num_contexts, static_context_map.not_nil!, mb)
      end
    end

    # metablock.c:206 — RecomputeDistancePrefixes: rewrite the distance
    # prefix/extra of every copy command for the new npostfix/ndirect.
    def self.recompute_distance_prefixes(cmds : Array(Command),
                                         num_commands : Int32,
                                         orig_params : DistanceParams,
                                         new_params : DistanceParams) : Nil
      return if orig_params.distance_postfix_bits ==
                new_params.distance_postfix_bits &&
                orig_params.num_direct_distance_codes ==
                new_params.num_direct_distance_codes
      num_commands.times do |i|
        cmd = cmds.unsafe_fetch(i)
        if cmd.copy_len != 0 && cmd.cmd_prefix >= 128
          distance = cmd.restore_distance_code(orig_params)
          cmd.dist_prefix, cmd.dist_extra = Enc.prefix_encode_copy_distance(
            distance.to_u64!, new_params.num_direct_distance_codes,
            new_params.distance_postfix_bits)
          cmds[i] = cmd # Command is a struct: write the copy back
        end
      end
    end

    # metablock.c:230 — {ok, cost} of recoding distances under new_params.
    private def self.compute_distance_cost(cmds : Array(Command),
                                           num_commands : Int32,
                                           orig_params : DistanceParams,
                                           new_params : DistanceParams) : {Bool, Float64}
      equal_params = orig_params.distance_postfix_bits ==
                     new_params.distance_postfix_bits &&
                     orig_params.num_direct_distance_codes ==
                     new_params.num_direct_distance_codes
      tmp = Histogram.distance
      extra_bits = 0.0
      num_commands.times do |i|
        cmd = cmds.unsafe_fetch(i)
        next unless cmd.copy_len != 0 && cmd.cmd_prefix >= 128
        if equal_params
          dist_prefix = cmd.dist_prefix
        else
          distance = cmd.restore_distance_code(orig_params)
          return {false, 0.0} if distance > new_params.max_distance
          dist_prefix, _extra = Enc.prefix_encode_copy_distance(
            distance.to_u64!, new_params.num_direct_distance_codes,
            new_params.distance_postfix_bits)
        end
        tmp.add(dist_prefix & 0x3FF)
        extra_bits += (dist_prefix >> 10)
      end
      {true, population_cost(tmp) + extra_bits}
    end

    # metablock.c:274 — BrotliBuildMetaBlock, the HQ path (q10+): tunes
    # NPOSTFIX/NDIRECT over a grid, splits, builds histograms with literal
    # contexts and clusters them (up to 256 histograms per category).
    # `params.dist` is mutated to the winning distance parameters, as in C
    # (the caller passes a copy of the encoder params). Base64 regions and
    # compound dictionaries are out of scope.
    def self.build_meta_block(ringbuffer : Bytes, pos : Int32, mask : Int32,
                              params : Params, prev_byte : UInt8,
                              prev_byte2 : UInt8,
                              commands : Array(Command), num_commands : Int32,
                              literal_context_mode : Int32,
                              mb : MetaBlockSplit) : Nil
      # Histogram ids need to fit in one byte.
      max_number_of_histograms = 256
      literal_context_multiplier = 1
      ndirect_msb = 0_u32
      check_orig = true
      best_dist_cost = 1e99
      orig_params = params.dist.dup
      new_params = params.dist.dup

      npostfix = 0_u32
      while npostfix <= Brotli::MAX_NPOSTFIX
        while ndirect_msb < 16
          ndirect = ndirect_msb << npostfix
          Enc.init_distance_params(new_params, npostfix, ndirect)
          if npostfix == orig_params.distance_postfix_bits &&
             ndirect == orig_params.num_direct_distance_codes
            check_orig = false
          end
          ok, dist_cost = compute_distance_cost(commands, num_commands,
                                                orig_params, new_params)
          break if !ok || dist_cost > best_dist_cost
          best_dist_cost = dist_cost
          params.dist.copy_from(new_params)
          ndirect_msb += 1
        end
        ndirect_msb -= 1 if ndirect_msb > 0
        ndirect_msb //= 2
        npostfix += 1
      end
      if check_orig
        ok, dist_cost = compute_distance_cost(commands, num_commands,
                                              orig_params, orig_params)
        if dist_cost < best_dist_cost
          params.dist.copy_from(orig_params)
        end
      end
      recompute_distance_prefixes(commands, num_commands, orig_params,
                                  params.dist)

      Enc.split_block(commands[0, num_commands], ringbuffer, pos, mask,
                      params.quality, mb.literal_split, mb.command_split,
                      mb.distance_split)

      literal_context_modes : Slice(Int32)? = nil
      unless params.disable_literal_context_modeling
        literal_context_multiplier = 1 << Brotli::LITERAL_CONTEXT_BITS
        modes = Slice(Int32).new(mb.literal_split.num_types)
        modes.fill(literal_context_mode)
        literal_context_modes = modes
      end

      literal_histograms_size =
        mb.literal_split.num_types * literal_context_multiplier
      literal_histograms = Array(Histogram).new(literal_histograms_size) do
        Histogram.literal
      end
      distance_histograms_size =
        mb.distance_split.num_types << Brotli::DISTANCE_CONTEXT_BITS
      distance_histograms = Array(Histogram).new(distance_histograms_size) do
        Histogram.distance
      end
      mb.command_histograms = Array(Histogram).new(
        mb.command_split.num_types) { Histogram.command }

      build_histograms_with_context(
        commands[0, num_commands], mb.literal_split, mb.command_split,
        mb.distance_split, ringbuffer, pos, mask, prev_byte, prev_byte2,
        literal_context_modes, literal_histograms, mb.command_histograms,
        distance_histograms)

      mb.literal_context_map = Slice(UInt32).new(
        mb.literal_split.num_types << Brotli::LITERAL_CONTEXT_BITS)
      literal_out = Array(Histogram).new(mb.literal_context_map.not_nil!.size) do
        Histogram.literal
      end
      literal_histograms_size = cluster_histograms(
        literal_histograms, max_number_of_histograms, literal_out,
        mb.literal_context_map.not_nil!)
      mb.literal_histograms = literal_out[0, literal_histograms_size]

      if params.disable_literal_context_modeling
        # Distribute assignment to all contexts.
        lcmap = mb.literal_context_map.not_nil!
        (mb.literal_split.num_types - 1).downto(0) do |i|
          Brotli::LITERAL_CONTEXT_BITS.times do |j|
            lcmap[(i << Brotli::LITERAL_CONTEXT_BITS) &+ j] =
              lcmap.unsafe_fetch(i)
          end
        end
      end

      mb.distance_context_map = Slice(UInt32).new(distance_histograms_size)
      distance_out = Array(Histogram).new(distance_histograms_size) do
        Histogram.distance
      end
      distance_histograms_size = cluster_histograms(
        distance_histograms, max_number_of_histograms, distance_out,
        mb.distance_context_map.not_nil!)
      mb.distance_histograms = distance_out[0, distance_histograms_size]
    end

    # metablock.c:841 — BrotliOptimizeHistograms.
    def self.optimize_histograms(num_distance_codes : Int32,
                                 mb : MetaBlockSplit) : Nil
      good_for_rle = Bytes.new(Brotli::NUM_COMMAND_SYMBOLS)
      mb.literal_histograms.each do |h|
        optimize_huffman_counts_for_rle(256, h.data, good_for_rle)
      end
      mb.command_histograms.each do |h|
        optimize_huffman_counts_for_rle(Brotli::NUM_COMMAND_SYMBOLS, h.data,
                                        good_for_rle)
      end
      mb.distance_histograms.each do |h|
        optimize_huffman_counts_for_rle(num_distance_codes, h.data,
                                        good_for_rle)
      end
    end

    # encode.c:265 — plain Shannon entropy (not BitsEntropy: the prefix is
    # encoded together with the following symbol).
    private def self.estimate_entropy(population : Slice(UInt32),
                                      size : Int32) : Float64
      total = 0_u64
      result = 0.0
      i = 0
      while i < size
        p = population.unsafe_fetch(i)
        total &+= p
        result += p.to_f64 * fast_log2(p)
        i += 1
      end
      total.to_f64 * fast_log2(total) - result
    end

    STATIC_CONTEXT_MAP_CONTINUATION = Slice[
      1_u32, 1_u32, 2_u32, 2_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32]

    STATIC_CONTEXT_MAP_SIMPLE_UTF8 = Slice[
      0_u32, 0_u32, 1_u32, 1_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32]

    STATIC_CONTEXT_MAP_COMPLEX_UTF8 = Slice[
      11_u32, 11_u32, 12_u32, 12_u32, # 0 special
      0_u32, 0_u32, 0_u32, 0_u32,     # 4 lf
      1_u32, 1_u32, 9_u32, 9_u32,     # 8 space
      2_u32, 2_u32, 2_u32, 2_u32,     # !, first after space/lf
      1_u32, 1_u32, 1_u32, 1_u32,     # "
      8_u32, 3_u32, 3_u32, 3_u32,     # %
      1_u32, 1_u32, 1_u32, 1_u32,     # ({[
      2_u32, 2_u32, 2_u32, 2_u32,     # }])
      8_u32, 4_u32, 4_u32, 4_u32,     # :;
      8_u32, 7_u32, 4_u32, 4_u32,     # .
      8_u32, 0_u32, 0_u32, 0_u32,     # >
      3_u32, 3_u32, 3_u32, 3_u32,     # [0..9]
      5_u32, 5_u32, 10_u32, 5_u32,    # [A-Z]
      5_u32, 5_u32, 10_u32, 5_u32,
      6_u32, 6_u32, 6_u32, 6_u32,     # [a-z]
      6_u32, 6_u32, 6_u32, 6_u32]

    # encode.c:287
    private def self.choose_context_map(quality : Int32,
                                        bigram_histo : Slice(UInt32),
                                        num_literal_contexts : Pointer(Int32),
                                        literal_context_map : Pointer(Slice(UInt32))) : Nil
      monogram_histo = StaticArray(UInt32, 3).new(0_u32)
      two_prefix_histo = StaticArray(UInt32, 6).new(0_u32)
      entropy = StaticArray(Float64, 4).new(0.0)
      i = 0
      while i < 9
        monogram_histo[i % 3] &+= bigram_histo.unsafe_fetch(i)
        two_prefix_histo[i % 6] &+= bigram_histo.unsafe_fetch(i)
        i += 1
      end
      entropy[1] = estimate_entropy(monogram_histo.to_slice, 3)
      entropy[2] = estimate_entropy(two_prefix_histo.to_slice[0, 3], 3) +
                   estimate_entropy(two_prefix_histo.to_slice[3, 3], 3)
      entropy[3] = 0.0
      i = 0
      while i < 3
        entropy[3] += estimate_entropy(
          bigram_histo.to_slice[3 * i, 3], 3)
        i += 1
      end

      total = monogram_histo[0] &+ monogram_histo[1] &+ monogram_histo[2]
      entropy[0] = 1.0 / total.to_f64
      entropy[1] *= entropy[0]
      entropy[2] *= entropy[0]
      entropy[3] *= entropy[0]

      if quality < MIN_QUALITY_FOR_HQ_CONTEXT_MODELING
        # 3 context models is a bit slower, don't use it at lower qualities.
        entropy[3] = entropy[1] * 10
      end
      # If expected savings by symbol are less than 0.2 bits, skip the
      # context modeling -- in exchange for faster decoding speed.
      if entropy[1] - entropy[2] < 0.2 && entropy[1] - entropy[3] < 0.2
        num_literal_contexts.value = 1
      elsif entropy[2] - entropy[3] < 0.02
        num_literal_contexts.value = 2
        literal_context_map.value = STATIC_CONTEXT_MAP_SIMPLE_UTF8
      else
        num_literal_contexts.value = 3
        literal_context_map.value = STATIC_CONTEXT_MAP_CONTINUATION
      end
    end

    # encode.c:351
    private def self.should_use_complex_static_context_map(
        input : Bytes, start_pos : Int32, length : Int32, mask : Int32,
        size_hint : Int32, num_literal_contexts : Pointer(Int32),
        literal_context_map : Pointer(Slice(UInt32))) : Bool
      # Try the more complex static context map only for long data.
      return false if size_hint < (1 << 20)
      end_pos = start_pos + length
      combined_histo = Slice(UInt32).new(32)
      context_histo = Slice(UInt32).new(32 * MAX_STATIC_CONTEXTS)
      total = 0_u64
      pos0 = start_pos
      while pos0 + 64 <= end_pos
        stride_end_pos = pos0 + 64
        prev2 = input.unsafe_fetch(pos0 & mask)
        prev1 = input.unsafe_fetch((pos0 + 1) & mask)
        pos = pos0 + 2
        while pos < stride_end_pos
          literal = input.unsafe_fetch(pos & mask)
          ctx = CONTEXT_LOOKUP.unsafe_fetch((2 << 9) | prev1).to_i32 |
                CONTEXT_LOOKUP.unsafe_fetch((2 << 9) | 256 | prev2).to_i32
          context = STATIC_CONTEXT_MAP_COMPLEX_UTF8.unsafe_fetch(ctx)
          total &+= 1
          combined_histo[literal >> 3] &+= 1
          context_histo[(context << 5) &+ (literal >> 3)] &+= 1
          prev2 = prev1
          prev1 = literal
          pos += 1
        end
        pos0 += 4096
      end
      entropy1 = estimate_entropy(combined_histo, 32)
      entropy2 = 0.0
      i = 0
      while i < MAX_STATIC_CONTEXTS
        entropy2 += estimate_entropy(context_histo + (i << 5), 32)
        i += 1
      end
      entropy0 = 1.0 / total.to_f64
      entropy1 *= entropy0
      entropy2 *= entropy0
      if entropy2 > 3.0 || entropy1 - entropy2 < 0.2
        false
      else
        num_literal_contexts.value = MAX_STATIC_CONTEXTS
        literal_context_map.value = STATIC_CONTEXT_MAP_COMPLEX_UTF8
        true
      end
    end

    # encode.c:433
    def self.decide_over_literal_context_modeling(
        input : Bytes, start_pos : Int32, length : Int32, mask : Int32,
        quality : Int32, size_hint : Int32,
        num_literal_contexts : Pointer(Int32),
        literal_context_map : Pointer(Slice(UInt32))) : Nil
      if quality < MIN_QUALITY_FOR_CONTEXT_MODELING || length < 64
        return
      elsif should_use_complex_static_context_map(
          input, start_pos, length, mask, size_hint,
          num_literal_contexts, literal_context_map)
        # Context map was already set, nothing else to do.
      else
        # Gather bi-gram data of the UTF8 byte prefixes: 64 byte long
        # strides at every 4kB intervals.
        end_pos = start_pos + length
        bigram_prefix_histo = Slice(UInt32).new(9)
        lut = StaticArray(Int32, 4).new(0)
        lut[2] = 1
        lut[3] = 2
        pos0 = start_pos
        while pos0 + 64 <= end_pos
          stride_end_pos = pos0 + 64
          prev = lut[input.unsafe_fetch(pos0 & mask) >> 6] * 3
          pos = pos0 + 1
          while pos < stride_end_pos
            literal = input.unsafe_fetch(pos & mask)
            bigram_prefix_histo[prev + lut[literal >> 6]] &+= 1
            prev = lut[literal >> 6] * 3
            pos += 1
          end
          pos0 += 4096
        end
        choose_context_map(quality, bigram_prefix_histo,
                           num_literal_contexts, literal_context_map)
      end
    end
  end
end
