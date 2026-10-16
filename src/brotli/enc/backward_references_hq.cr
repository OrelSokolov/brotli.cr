# Port of c/enc/backward_references_hq.{c,h}: Zopfli shortest-path backward
# references for q10 (single pass) and q11 (two-pass HQ). Upstream: 42a2ed4.
#
# Compound/contextual dictionaries are out of scope (gap = 0), so the
# compound-dictionary branches in UpdateNodes are cut; the "gray zone"
# between max_distance and dictionary_start (only reachable when
# position_offset > 0) is skipped, matching our fragment-per-window model.
#
# All cost math is Float32, as in C (kInfinity = 1.7e38f).

module Brotli
  module Enc
    # backward_references_hq.c:33 (kInfinity ~= 2^127)
    ZOFLI_INFINITY = 1.7e38_f32

    # backward_references_hq.c:35
    DISTANCE_CACHE_INDEX  = [0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1]
    DISTANCE_CACHE_OFFSET = [0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3]

    # backward_references_hq.h:20. C packs {length, distance,
    # dcode_insert_length, u.cost/shortcut/next} into 16 bytes with a union
    # for the last field; the union aliases cost with shortcut/next, but
    # every read happens before the aliasing write (EvaluateNode saves the
    # cost first, ComputeShortestPathFromNodes runs after all cost reads),
    # so separate fields preserve the semantics exactly.
    class ZopfliNode
      property length : UInt32
      property distance : UInt32
      property dcode_insert_length : UInt32
      property cost : Float32
      property shortcut : UInt32
      property next : UInt32

      def initialize
        @length = 1_u32
        @distance = 0_u32
        @dcode_insert_length = 0_u32
        @cost = ZOFLI_INFINITY
        @shortcut = 0_u32
        @next = 0_u32
      end

      # ZopfliNodeCopyLength
      def copy_length : Int32
        (@length & 0x1FFFFFF).to_i32!
      end

      # ZopfliNodeLengthCode
      def length_code : Int32
        modifier = (@length >> 25).to_i32
        copy_length &+ 9 &- modifier
      end

      # ZopfliNodeCopyDistance
      def copy_distance : Int32
        @distance.to_i32!
      end

      # ZopfliNodeDistanceCode
      def distance_code : Int32
        short_code = (@dcode_insert_length >> 27).to_i32
        short_code == 0 ? copy_distance &+ Brotli::NUM_DISTANCE_SHORT_CODES &- 1 :
                          short_code &- 1
      end

      # ZopfliNodeCommandLength
      def command_length : Int32
        copy_length &+ (@dcode_insert_length & 0x7FFFFFF).to_i32!
      end

      def insert_length : Int32
        (@dcode_insert_length & 0x7FFFFFF).to_i32!
      end
    end

    # backward_references_hq.c:42 — BrotliInitZopfliNodes.
    def self.init_zopfli_nodes(array : Array(ZopfliNode)) : Nil
      array.each do |node|
        node.length = 1_u32
        node.distance = 0_u32
        node.dcode_insert_length = 0_u32
        node.cost = ZOFLI_INFINITY
      end
    end

    # backward_references_hq.c:117 — Shannon cost per symbol.
    def self.zopfli_set_cost(histogram : Slice(UInt32),
                                     histogram_size : Int32,
                                     literal_histogram : Bool,
                                     cost : Slice(Float32)) : Nil
      sum = 0_u64
      histogram_size.times { |i| sum &+= histogram.unsafe_fetch(i) }
      log2sum = Enc.fast_log2(sum).to_f32!
      missing_symbol_sum = sum
      unless literal_histogram
        histogram_size.times do |i|
          missing_symbol_sum &+= 1 if histogram.unsafe_fetch(i) == 0
        end
      end
      missing_symbol_cost = Enc.fast_log2(missing_symbol_sum).to_f32! + 2.0_f32
      histogram_size.times do |i|
        h = histogram.unsafe_fetch(i)
        if h == 0
          cost[i] = missing_symbol_cost
        else
          c = log2sum - Enc.fast_log2(h).to_f32!
          cost[i] = c < 1.0_f32 ? 1.0_f32 : c
        end
      end
    end

    # Histogram based cost model for zopflification.
    class ZopfliCostModel
      property num_bytes : Int32
      property distance_histogram_size : Int32
      property min_cost_cmd : Float32
      property cost_cmd : Slice(Float32)
      property cost_dist : Slice(Float32)
      property literal_costs : Slice(Float32)

      # Temporary data (C: ZopfliCostModelArena + literal_histograms union).
      property histogram_literal : Slice(UInt32)
      property histogram_cmd : Slice(UInt32)
      property histogram_dist : Slice(UInt32)
      property cost_literal : Slice(Float32)
      # 3 * 256 scratch for estimate_bit_costs_for_literals.
      property literal_histogram_scratch : Slice(UInt32)

      def initialize(dist : DistanceParams, num_bytes : Int32)
        @num_bytes = num_bytes
        @distance_histogram_size = dist.alphabet_size_limit.to_i32!
        @min_cost_cmd = ZOFLI_INFINITY
        @cost_cmd = Slice(Float32).new(Brotli::NUM_COMMAND_SYMBOLS)
        @cost_dist = Slice(Float32).new(@distance_histogram_size)
        @literal_costs = Slice(Float32).new(num_bytes + 2)
        @histogram_literal = Slice(UInt32).new(Brotli::NUM_LITERAL_SYMBOLS)
        @histogram_cmd = Slice(UInt32).new(Brotli::NUM_COMMAND_SYMBOLS)
        @histogram_dist = Slice(UInt32).new(544)
        @cost_literal = Slice(Float32).new(Brotli::NUM_LITERAL_SYMBOLS)
        @literal_histogram_scratch = Slice(UInt32).new(3 * 256)
      end

      # ZopfliCostModelSetFromCommands. `commands` is the base of the run,
      # `num_commands` its length (C passes commands + orig offset).
      def set_from_commands(position : Int32, ringbuffer : Bytes,
                            ringbuffer_mask : Int32,
                            commands : Array(Command), base : Int32,
                            num_commands : Int32,
                            last_insert_len : Int32) : Nil
        return if num_commands <= 0 # NB: x.step(to: x-1) iterates downward!
        histogram_literal.fill(0)
        histogram_cmd.fill(0)
        histogram_dist.fill(0, 0, distance_histogram_size)

        pos = position - last_insert_len
        base.step(to: base + num_commands - 1) do |i|
          cmd = commands.unsafe_fetch(i)
          inslength = cmd.insert_len.to_i32!
          copylength = cmd.copy_len.to_i32!
          distcode = cmd.dist_prefix & 0x3FF
          cmdcode = cmd.cmd_prefix
          histogram_cmd[cmdcode] &+= 1
          histogram_dist[distcode] &+= 1 if cmdcode >= 128
          inslength.times do |j|
            histogram_literal[ringbuffer.unsafe_fetch((pos &+ j) & ringbuffer_mask)] &+= 1
          end
          pos += inslength + copylength
        end

        Enc.zopfli_set_cost(histogram_literal, Brotli::NUM_LITERAL_SYMBOLS,
                            true, cost_literal)
        Enc.zopfli_set_cost(histogram_cmd, Brotli::NUM_COMMAND_SYMBOLS,
                            false, cost_cmd)
        Enc.zopfli_set_cost(histogram_dist, distance_histogram_size,
                            false, cost_dist)

        min_cost_cmd = ZOFLI_INFINITY
        Brotli::NUM_COMMAND_SYMBOLS.times do |i|
          c = cost_cmd.unsafe_fetch(i)
          min_cost_cmd = c if c < min_cost_cmd
        end
        self.min_cost_cmd = min_cost_cmd

        literal_carry = 0.0_f32
        literal_costs[0] = 0.0_f32
        num_bytes.times do |i|
          literal_carry += cost_literal.unsafe_fetch(
            ringbuffer.unsafe_fetch((position &+ i) & ringbuffer_mask))
          literal_costs[i + 1] = literal_costs[i] + literal_carry
          literal_carry -= literal_costs[i &+ 1] - literal_costs[i]
        end
      end

      # ZopfliCostModelSetFromLiteralCosts.
      def set_from_literal_costs(position : Int32, ringbuffer : Bytes,
                                 ringbuffer_mask : Int32) : Nil
        Enc.estimate_bit_costs_for_literals(
          position, num_bytes, ringbuffer_mask, ringbuffer,
          literal_histogram_scratch,
          Slice(Float32).new(@literal_costs.to_unsafe + 1, num_bytes))
        literal_costs[0] = 0.0_f32
        literal_carry = 0.0_f32
        num_bytes.times do |i|
          literal_carry += literal_costs.unsafe_fetch(i &+ 1)
          literal_costs[i + 1] = literal_costs.unsafe_fetch(i) + literal_carry
          literal_carry -= literal_costs[i &+ 1] - literal_costs[i]
        end
        Brotli::NUM_COMMAND_SYMBOLS.times do |i|
          cost_cmd[i] = Enc.fast_log2(11 &+ i).to_f32!
        end
        distance_histogram_size.times do |i|
          cost_dist[i] = Enc.fast_log2(20 &+ i).to_f32!
        end
        self.min_cost_cmd = Enc.fast_log2(11).to_f32!
      end

      def get_command_cost(cmdcode : Int32) : Float32
        cost_cmd.unsafe_fetch(cmdcode)
      end

      def get_distance_cost(distcode : Int32) : Float32
        cost_dist.unsafe_fetch(distcode)
      end

      def get_literal_costs(from_pos : Int32, to_pos : Int32) : Float32
        literal_costs.unsafe_fetch(to_pos) -
          literal_costs.unsafe_fetch(from_pos)
      end
    end

    # backward_references_hq.c:260 — UpdateZopfliNode.
    private def self.update_zopfli_node(nodes : Array(ZopfliNode), pos : Int32,
                                        start_pos : Int32, len : Int32,
                                        len_code : Int32, dist : Int32,
                                        short_code : Int32,
                                        cost : Float32) : Nil
      nxt = nodes.unsafe_fetch(pos &+ len)
      nxt.length = (len | ((len &+ 9 &- len_code) << 25)).to_u32!
      nxt.distance = dist.to_u32!
      nxt.dcode_insert_length = ((short_code << 27) | (pos &- start_pos)).to_u32!
      nxt.cost = cost
    end

    # backward_references_hq.c:271
    class PosData
      property pos : Int32
      property distance_cache : StaticArray(Int32, 4)
      property costdiff : Float32
      property cost : Float32

      def initialize(@pos : Int32, @distance_cache : StaticArray(Int32, 4),
                     @costdiff : Float32, @cost : Float32)
      end
    end

    # backward_references_hq.c:279 — the smallest 8 cost differences.
    class StartPosQueue
      @q : Array(PosData)
      @idx : Int32

      def initialize
        @q = Array(PosData).new(8) { PosData.new(0, StaticArray(Int32, 4).new(0), 0.0_f32, 0.0_f32) }
        @idx = 0
      end

      # StartPosQueueSize
      def size : Int32
        Math.min(@idx, 8)
      end

      # StartPosQueuePush
      def push(posdata : PosData) : Nil
        offset = ~@idx & 7
        @idx += 1
        len = size
        @q[offset] = posdata
        # Restore the sorted order: at most len - 1 adjacent swaps.
        (1...len).each do |_|
          if @q[offset & 7].costdiff > @q[(offset &+ 1) & 7].costdiff
            @q.swap(offset & 7, (offset &+ 1) & 7)
          end
          offset += 1
        end
      end

      # StartPosQueueAt
      def at(k : Int32) : PosData
        @q.unsafe_fetch((k &- @idx) & 7)
      end
    end

    # backward_references_hq.c:314 — ComputeMinimumCopyLength.
    private def self.compute_minimum_copy_length(start_cost : Float32,
                                                 nodes : Array(ZopfliNode),
                                                 num_bytes : Int32,
                                                 pos : Int32) : Int32
      min_cost = start_cost
      len = 2
      next_len_bucket = 4
      next_len_offset = 10
      while pos &+ len <= num_bytes &&
            nodes.unsafe_fetch(pos &+ len).cost <= min_cost
        len += 1
        if len == next_len_offset
          min_cost += 1.0_f32
          next_len_offset &+= next_len_bucket
          next_len_bucket *= 2
        end
      end
      len
    end

    # backward_references_hq.c:341 — ComputeDistanceShortcut. gap is
    # always 0 (no compound dictionary).
    private def self.compute_distance_shortcut(block_start : Int32,
                                               pos : Int32,
                                               max_backward_limit : Int32,
                                               nodes : Array(ZopfliNode)) : UInt32
      node = nodes.unsafe_fetch(pos)
      c_len = node.copy_length
      i_len = node.insert_length
      dist = node.copy_distance
      if pos == 0
        0_u32
      elsif dist &+ c_len <= block_start &+ pos &&
            dist <= max_backward_limit &&
            node.distance_code > 0
        pos.to_u32!
      else
        nodes.unsafe_fetch(pos &- c_len &- i_len).shortcut
      end
    end

    # backward_references_hq.c:372 — ComputeDistanceCache.
    private def self.compute_distance_cache(pos : Int32,
                                            starting_dist_cache : Slice(Int32),
                                            nodes : Array(ZopfliNode),
                                            dist_cache : Slice(Int32)) : Nil
      idx = 0
      p = nodes.unsafe_fetch(pos).shortcut
      while idx < 4 && p > 0
        node = nodes.unsafe_fetch(p)
        i_len = node.insert_length
        c_len = node.copy_length
        dist_cache[idx] = node.copy_distance
        idx += 1
        p = nodes.unsafe_fetch(p &- c_len &- i_len).shortcut
      end
      s = 0
      while idx < 4
        dist_cache[idx] = starting_dist_cache.unsafe_fetch(s)
        idx += 1
        s += 1
      end
    end

    # backward_references_hq.c:393 — EvaluateNode.
    private def self.evaluate_node(block_start : Int32, pos : Int32,
                                   max_backward_limit : Int32,
                                   starting_dist_cache : Slice(Int32),
                                   model : ZopfliCostModel,
                                   queue : StartPosQueue,
                                   nodes : Array(ZopfliNode)) : Nil
      node = nodes.unsafe_fetch(pos)
      # Save cost: in C, ComputeDistanceShortcut overwrites the union slot;
      # with separate fields nothing is destroyed, but the logic is the same.
      node_cost = node.cost
      node.shortcut = compute_distance_shortcut(block_start, pos,
                                                max_backward_limit, nodes)
      if node_cost <= model.get_literal_costs(0, pos)
        dc = StaticArray(Int32, 4).new(0)
        compute_distance_cache(pos, starting_dist_cache, nodes,
                                dc.to_slice)
        queue.push(PosData.new(pos, dc,
                               node_cost - model.get_literal_costs(0, pos),
                               node_cost))
      end
    end

    # backward_references_hq.c:414 — UpdateNodes. Returns longest copy length.
    private def self.update_nodes(num_bytes : Int32, block_start : Int32,
                                  pos : Int32, ringbuffer : Bytes,
                                  ringbuffer_mask : Int32, params : Params,
                                  position_offset : Int32,
                                  max_backward_limit : Int32,
                                  starting_dist_cache : Slice(Int32),
                                  num_matches : Int32,
                                  matches : Slice(BackwardMatch),
                                  model : ZopfliCostModel,
                                  queue : StartPosQueue,
                                  nodes : Array(ZopfliNode)) : Int32
      cur_ix = block_start &+ pos
      cur_ix_masked = cur_ix & ringbuffer_mask
      max_distance = Math.min(cur_ix, max_backward_limit)
      dictionary_start = Math.min(cur_ix &+ position_offset,
                                  max_backward_limit)
      max_len = num_bytes &- pos
      max_zopfli_len = Enc.max_zopfli_len(params)
      max_iters = Enc.max_zopfli_candidates(params)
      result = 0

      evaluate_node(block_start &+ position_offset, pos, max_backward_limit,
                    starting_dist_cache, model, queue, nodes)

      posdata0 = queue.at(0)
      min_cost = posdata0.cost + model.min_cost_cmd +
                 model.get_literal_costs(posdata0.pos, pos)
      min_len = compute_minimum_copy_length(min_cost, nodes, num_bytes, pos)

      # Command starting positions in order of increasing cost difference.
      k = 0
      while k < max_iters && k < queue.size
        posdata = queue.at(k)
        start = posdata.pos
        inscode = Enc.insert_length_code(pos &- start)
        start_costdiff = posdata.costdiff
        base_cost = start_costdiff +
                    Enc.insert_extra(inscode).to_f32! +
                    model.get_literal_costs(0, pos)

        # Last distance matches from this starting position's distance cache.
        best_len = min_len &- 1
        j = 0
        while j < Brotli::NUM_DISTANCE_SHORT_CODES && best_len < max_len
          idx = DISTANCE_CACHE_INDEX.unsafe_fetch(j)
          backward = posdata.distance_cache.unsafe_fetch(idx) &+
                     DISTANCE_CACHE_OFFSET.unsafe_fetch(j)
          prev_ix = cur_ix &- backward
          len = 0
          continuation = ringbuffer.unsafe_fetch(cur_ix_masked &+ best_len)
          break if cur_ix_masked &+ best_len > ringbuffer_mask
          if backward > dictionary_start
            # Static dictionary word -> ignore (handled via matches).
            j += 1
            next
          end
          if backward <= max_distance
            # Regular backward reference.
            if prev_ix >= cur_ix
              j += 1
              next
            end
            prev_ix &= ringbuffer_mask
            if prev_ix &+ best_len > ringbuffer_mask ||
               continuation != ringbuffer.unsafe_fetch(prev_ix &+ best_len)
              j += 1
              next
            end
            len = Enc.find_match_length_with_limit(ringbuffer, prev_ix,
                                                   cur_ix_masked, max_len)
          else
            # "Gray" area: addressable by the decoder, but this encoder
            # instance does not have that data (fragment model).
            j += 1
            next
          end
          dist_cost = base_cost + model.get_distance_cost(j)
          l = best_len &+ 1
          while l <= len
            copycode = Enc.copy_length_code(l)
            cmdcode = Enc.combine_length_codes(inscode, copycode, j == 0)
            cost = (cmdcode < 128 ? base_cost : dist_cost) +
                   Enc.copy_extra(copycode).to_f32! +
                   model.get_command_cost(cmdcode)
            if cost < nodes.unsafe_fetch(pos &+ l).cost
              update_zopfli_node(nodes, pos, start, l, l, backward, j &+ 1,
                                 cost)
              result = {result, l}.max
            end
            best_len = l
            l += 1
          end
          j += 1
        end

        # At higher iterations look only for new last distance matches.
        k += 1
        next if k >= 2

        # Loop through all possible copy lengths at this position.
        len = min_len
        j = 0
        while j < num_matches
          match = matches.unsafe_fetch(j)
          dist = match.distance.to_i32!
          is_dictionary_match = dist > dictionary_start
          # Last distance matches were already tried -> normal distance code.
          dist_code = dist &+ Brotli::NUM_DISTANCE_SHORT_CODES &- 1
          dist_symbol, _extra = Enc.prefix_encode_copy_distance(
            dist_code.to_u64!, params.dist.num_direct_distance_codes,
            params.dist.distance_postfix_bits)
          distnumextra = dist_symbol >> 10
          dist_cost = base_cost + distnumextra.to_f32! +
                      model.get_distance_cost(dist_symbol & 0x3FF)

          max_match_len = match.length
          if len < max_match_len &&
             (is_dictionary_match || max_match_len > max_zopfli_len)
            len = max_match_len
          end
          while len <= max_match_len
            len_code = is_dictionary_match ? match.length_code : len
            copycode = Enc.copy_length_code(len_code)
            cmdcode = Enc.combine_length_codes(inscode, copycode, false)
            cost = dist_cost + Enc.copy_extra(copycode).to_f32! +
                   model.get_command_cost(cmdcode)
            if cost < nodes.unsafe_fetch(pos &+ len).cost
              update_zopfli_node(nodes, pos, start, len, len_code, dist, 0,
                                 cost)
              result = {result, len}.max
            end
            len += 1
          end
          j += 1
        end
      end
      result
    end

    # backward_references_hq.c:585 — ComputeShortestPathFromNodes.
    private def self.compute_shortest_path_from_nodes(
        num_bytes : Int32, nodes : Array(ZopfliNode)) : Int32
      index = num_bytes
      num_commands = 0
      while nodes.unsafe_fetch(index).insert_length == 0 &&
            nodes.unsafe_fetch(index).length == 1
        index -= 1
      end
      nodes.unsafe_fetch(index).next = UInt32::MAX
      while index != 0
        len = nodes.unsafe_fetch(index).command_length
        index -= len
        nodes.unsafe_fetch(index).next = len.to_u32!
        num_commands += 1
      end
      num_commands
    end

    # backward_references_hq.c:602 — BrotliZopfliCreateCommands. Appends to
    # `commands`; mutates dist_cache; returns updated last_insert_len.
    def self.zopfli_create_commands(num_bytes : Int32, block_start : Int32,
                                    position_offset : Int32,
                                    nodes : Array(ZopfliNode),
                                    dist_cache : Slice(Int32),
                                    last_insert_len : Int32,
                                    params : Params,
                                    commands : Array(Command)) : {Int32, Int32}
      max_backward_limit = (1 << params.lgwin) - Brotli::WINDOW_GAP
      pos = 0
      num_literals = 0
      offset = nodes.unsafe_fetch(0).next
      i = 0
      insert_length_carry = last_insert_len
      while offset != UInt32::MAX
        nxt = nodes.unsafe_fetch(pos &+ offset)
        copy_length = nxt.copy_length
        insert_length = nxt.insert_length
        pos += insert_length
        offset = nxt.next
        if i == 0
          insert_length += insert_length_carry
          insert_length_carry = 0
        end
        distance = nxt.copy_distance
        len_code = nxt.length_code
        dictionary_start = Math.min(block_start &+ pos &+ position_offset,
                                    max_backward_limit)
        is_dictionary = distance > dictionary_start
        dist_code = nxt.distance_code
        commands << Command.new(insert_length, copy_length,
                                len_code &- copy_length,
                                dist_code.to_u64!, params.dist)
        unless is_dictionary || dist_code == 0
          dist_cache[3] = dist_cache[2]
          dist_cache[2] = dist_cache[1]
          dist_cache[1] = dist_cache[0]
          dist_cache[0] = distance
        end
        num_literals += insert_length
        pos += copy_length
        i += 1
      end
      {insert_length_carry &+ (num_bytes &- pos), num_literals}
    end

    # backward_references_hq.c:647 — ZopfliIterate (q11 second phase).
    def self.zopfli_iterate(num_bytes : Int32, position : Int32,
                            ringbuffer : Bytes, ringbuffer_mask : Int32,
                            params : Params, position_offset : Int32,
                            dist_cache : Slice(Int32),
                            model : ZopfliCostModel,
                            num_matches : Slice(UInt32),
                            matches : Slice(BackwardMatch),
                            nodes : Array(ZopfliNode)) : Int32
      max_backward_limit = (1 << params.lgwin) - Brotli::WINDOW_GAP
      max_zopfli_len = Enc.max_zopfli_len(params)
      queue = StartPosQueue.new
      cur_match_pos = 0
      nodes.unsafe_fetch(0).length = 0
      nodes.unsafe_fetch(0).cost = 0.0_f32
      i = 0
      while i &+ 3 < num_bytes
        skip = update_nodes(num_bytes, position, i, ringbuffer,
                            ringbuffer_mask, params, position_offset,
                            max_backward_limit, dist_cache,
                            num_matches.unsafe_fetch(i).to_i32!,
                            Slice(BackwardMatch).new(
                              matches.to_unsafe + cur_match_pos,
                              Math.max(matches.size - cur_match_pos, 0)),
                            model, queue, nodes)
        skip = 0 if skip < LONG_COPY_QUICK_STEP
        cur_match_pos += num_matches.unsafe_fetch(i)
        if num_matches.unsafe_fetch(i) == 1 &&
           matches.unsafe_fetch(cur_match_pos - 1).length > max_zopfli_len
          skip = {matches.unsafe_fetch(cur_match_pos - 1).length, skip}.max
        end
        if skip > 1
          skip -= 1
          while skip != 0
            i += 1
            break if i &+ 3 >= num_bytes
            evaluate_node(position &+ position_offset, i, max_backward_limit,
                          dist_cache, model, queue, nodes)
            cur_match_pos += num_matches.unsafe_fetch(i)
            skip -= 1
          end
        end
        i += 1
      end
      compute_shortest_path_from_nodes(num_bytes, nodes)
    end

    # backward_references_hq.c:705 — BrotliZopfliComputeShortestPath (q10).
    def self.zopfli_compute_shortest_path(num_bytes : Int32, position : Int32,
                                          ringbuffer : Bytes,
                                          ringbuffer_mask : Int32,
                                          params : Params,
                                          position_offset : Int32,
                                          dist_cache : Slice(Int32),
                                          hasher : BinaryTreeHasher,
                                          nodes : Array(ZopfliNode)) : Int32
      max_backward_limit = (1 << params.lgwin) - Brotli::WINDOW_GAP
      max_zopfli_len = Enc.max_zopfli_len(params)
      queue = StartPosQueue.new
      matches = Slice(BackwardMatch).new(
        2 * (BinaryTreeHasher::MAX_NUM_MATCHES_H10 + 64)) { BackwardMatch.new }
      store_end = num_bytes >= hasher.store_lookahead ?
                  position &+ num_bytes &- hasher.store_lookahead &+ 1 : position
      model = ZopfliCostModel.new(params.dist, num_bytes)
      nodes.unsafe_fetch(0).length = 0
      nodes.unsafe_fetch(0).cost = 0.0_f32
      model.set_from_literal_costs(position, ringbuffer, ringbuffer_mask)
      dict = EncoderDictionary.default
      i = 0
      while i &+ hasher.hash_type_length &- 1 < num_bytes
        pos = position &+ i
        max_distance = Math.min(pos, max_backward_limit)
        dictionary_start = Math.min(pos &+ position_offset,
                                    max_backward_limit)
        num_matches = hasher.find_all_matches(
          dict, ringbuffer, ringbuffer_mask, pos, num_bytes &- i,
          max_distance, dictionary_start, params, matches)
        if num_matches > 0 &&
           matches.unsafe_fetch(num_matches - 1).length > max_zopfli_len
          matches[0] = matches.unsafe_fetch(num_matches - 1)
          num_matches = 1
        end
        skip = update_nodes(num_bytes, position, i, ringbuffer,
                            ringbuffer_mask, params, position_offset,
                            max_backward_limit, dist_cache, num_matches,
                            matches, model, queue, nodes)
        skip = 0 if skip < LONG_COPY_QUICK_STEP
        if num_matches == 1 &&
           matches.unsafe_fetch(0).length > max_zopfli_len
          skip = {matches.unsafe_fetch(0).length, skip}.max
        end
        if skip > 1
          # Add the tail of the copy to the hasher.
          hasher.store_range(ringbuffer, ringbuffer_mask, pos &+ 1,
                             Math.min(pos &+ skip, store_end))
          skip -= 1
          while skip != 0
            i += 1
            break if i &+ hasher.hash_type_length &- 1 >= num_bytes
            evaluate_node(position &+ position_offset, i, max_backward_limit,
                          dist_cache, model, queue, nodes)
            skip -= 1
          end
        end
        i += 1
      end
      compute_shortest_path_from_nodes(num_bytes, nodes)
    end

    # backward_references_hq.c:795 — q10 entry point.
    def self.create_zopfli_backward_references(
        num_bytes : Int32, position : Int32, position_offset : Int32,
        ringbuffer : Bytes, ringbuffer_mask : Int32, params : Params,
        dist_cache : Slice(Int32), hasher : BinaryTreeHasher,
        last_insert_len : Int32, commands : Array(Command)) : {Int32, Int32}
      nodes = Array(ZopfliNode).new(num_bytes + 1) { ZopfliNode.new }
      init_zopfli_nodes(nodes)
      zopfli_compute_shortest_path(num_bytes, position, ringbuffer,
                                   ringbuffer_mask, params, position_offset,
                                   dist_cache, hasher, nodes)
      zopfli_create_commands(num_bytes, position, position_offset, nodes,
                             dist_cache, last_insert_len, params, commands)
    end

    # backward_references_hq.c:812 — q11 entry point (two-phase).
    def self.create_hq_zopfli_backward_references(
        num_bytes : Int32, position : Int32, position_offset : Int32,
        ringbuffer : Bytes, ringbuffer_mask : Int32, params : Params,
        dist_cache : Slice(Int32), hasher : BinaryTreeHasher,
        last_insert_len : Int32, commands : Array(Command)) : {Int32, Int32}
      max_backward_limit = (1 << params.lgwin) - Brotli::WINDOW_GAP
      num_matches = Slice(UInt32).new(num_bytes)
      matches_size = 4 &* num_bytes
      matches = Slice(BackwardMatch).new(matches_size) { BackwardMatch.new }
      store_end = num_bytes >= hasher.store_lookahead ?
                  position &+ num_bytes &- hasher.store_lookahead &+ 1 : position
      cur_match_pos = 0
      dict = EncoderDictionary.default

      # Phase 1: collect all matches.
      i = 0
      while i &+ hasher.hash_type_length &- 1 < num_bytes
        pos = position &+ i
        max_distance = Math.min(pos, max_backward_limit)
        dictionary_start = Math.min(pos &+ position_offset,
                                    max_backward_limit)
        max_length = num_bytes &- i
        if cur_match_pos &+ BinaryTreeHasher::MAX_NUM_MATCHES_H10 > matches.size
          grown = Slice(BackwardMatch).new(
            Math.max(matches.size * 2,
                     cur_match_pos + BinaryTreeHasher::MAX_NUM_MATCHES_H10)) { BackwardMatch.new }
          grown.copy_from(matches)
          matches = grown
        end
        num_found = hasher.find_all_matches(
          dict, ringbuffer, ringbuffer_mask, pos, max_length, max_distance,
          dictionary_start, params,
          Slice(BackwardMatch).new(matches.to_unsafe + cur_match_pos,
                                   matches.size - cur_match_pos))
        num_matches[i] = num_found.to_u32!
        if num_found > 0
          match_len = matches.unsafe_fetch(
            cur_match_pos &+ num_found &- 1).length
          if match_len > MAX_ZOPFLI_LEN_QUALITY_11
            skip = match_len &- 1
            matches[cur_match_pos] = matches.unsafe_fetch(
              cur_match_pos &+ num_found &- 1)
            cur_match_pos += 1
            num_matches[i] = 1_u32
            hasher.store_range(ringbuffer, ringbuffer_mask, pos &+ 1,
                               Math.min(pos &+ match_len, store_end))
            skip = Math.min(skip, num_bytes - i - 1)
            (1..skip).each { |k| num_matches[i &+ k] = 0_u32 }
            i += skip
          else
            cur_match_pos &+= num_found
          end
        end
        i += 1
      end

      # Phase 2: two DP passes — first with literal-cost model, then with a
      # model fitted to the commands the first pass produced.
      orig_num_literals = 0
      orig_last_insert_len = last_insert_len
      orig_dist_cache = dist_cache[0, 4].dup
      orig_num_commands = commands.size
      nodes = Array(ZopfliNode).new(num_bytes + 1) { ZopfliNode.new }
      model = ZopfliCostModel.new(params.dist, num_bytes)
      last_len = orig_last_insert_len
      num_literals = orig_num_literals
      2.times do |phase|
        init_zopfli_nodes(nodes)
        if phase == 0
          model.set_from_literal_costs(position, ringbuffer,
                                       ringbuffer_mask)
        else
          model.set_from_commands(position, ringbuffer, ringbuffer_mask,
                                  commands, orig_num_commands,
                                  commands.size - orig_num_commands,
                                  orig_last_insert_len)
        end
        while commands.size > orig_num_commands
          commands.pop
        end
        dist_cache[0, 4].copy_from(orig_dist_cache)
        zopfli_iterate(num_bytes, position, ringbuffer, ringbuffer_mask,
                       params, position_offset, dist_cache, model,
                       num_matches, matches, nodes)
        last_len, num_literals = zopfli_create_commands(
          num_bytes, position, position_offset, nodes, dist_cache,
          orig_last_insert_len, params, commands)
      end
      {last_len, num_literals}
    end
  end
end

