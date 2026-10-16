# Port of c/enc/hash.h + hash_base.h essentials and
# hash_longest_match_quickly_inc.h (H2/H3/H4/H54 instantiations of the
# quickly hasher used by qualities 2, 3, 4-large and 5-9 fallbacks).
# Upstream: 42a2ed4.
#
# Ring-buffer convention: `data` is the ring buffer, positions are absolute
# (unmasked); the buffer must be readable contiguously past the current
# position for max_length (+1) bytes, as in C.

module Brotli
  module Enc
    # hash.h:102-105 (score_t = size_t, 64-bit here).
    LITERAL_BYTE_SCORE = 135_i64
    DISTANCE_BIT_PENALTY = 30_i64
    SCORE_BASE = DISTANCE_BIT_PENALTY &* 8 &* 8 # 30 * 8 * sizeof(size_t)

    # hash.h:123
    def self.backward_reference_score(copy_length : Int,
                                      backward_reference_offset : Int) : UInt64
      (SCORE_BASE &+ LITERAL_BYTE_SCORE &* copy_length &-
       DISTANCE_BIT_PENALTY &* log2_floor_non_zero(backward_reference_offset))
        .to_u64!
    end

    # hash.h:136
    def self.backward_reference_score_using_last_distance(
        copy_length : Int) : UInt64
      (LITERAL_BYTE_SCORE &* copy_length &+ SCORE_BASE &+ 15).to_u64!
    end

    # hash.h:142
    def self.backward_reference_penalty_using_last_distance(
        distance_short_code : Int) : UInt64
      (39 &+ ((0x1CA10 >> (distance_short_code & 0xE)) & 0xE)).to_u64!
    end

    # hash.h:133 — minimum match length that improves on `score`.
    def self.minimum_better_length(score : UInt64) : Int32
      ((score.to_i64! &- (SCORE_BASE &+ 15)) // LITERAL_BYTE_SCORE).to_i32!
    end

    # hash.h:59 — search result accumulator; `score` is only updated when a
    # better match is found.
    class HasherSearchResult
      property len : Int32
      property len_code_delta : Int32
      property distance : Int32
      property score : UInt64

      def initialize
        @len = 0
        @len_code_delta = 0
        @distance = 0
        @score = 0
      end
    end

    # Per-hasher shared state (counters used by the dictionary gate).
    class HasherCommon
      property dict_num_lookups : Int32
      property dict_num_matches : Int32

      def initialize
        @dict_num_lookups = 0
        @dict_num_matches = 0
      end
    end

    # hash.h:80 — extends the 4-entry distance cache with the derived
    # +/-1/2/3 candidates the hashers probe (indices 4..15).
    def self.prepare_distance_cache(distance_cache : Slice(Int32),
                                    num_distances : Int32) : Nil
      return unless num_distances > 4
      last_distance = distance_cache.unsafe_fetch(0)
      distance_cache[4] = last_distance &- 1
      distance_cache[5] = last_distance &+ 1
      distance_cache[6] = last_distance &- 2
      distance_cache[7] = last_distance &+ 2
      distance_cache[8] = last_distance &- 3
      distance_cache[9] = last_distance &+ 3
      if num_distances > 10
        next_last_distance = distance_cache.unsafe_fetch(1)
        distance_cache[10] = next_last_distance &- 1
        distance_cache[11] = next_last_distance &+ 1
        distance_cache[12] = next_last_distance &- 2
        distance_cache[13] = next_last_distance &+ 2
        distance_cache[14] = next_last_distance &- 3
        distance_cache[15] = next_last_distance &+ 3
      end
    end

    # The hasher interface consumed by create_backward_references
    # (C accesses it through the Hasher vtable; here it is a module).
    module Hasher
      abstract def hash_type_length : Int32
      abstract def store_lookahead : Int32
      abstract def prepare(data : Bytes, one_shot : Bool, input_size : Int32) : Nil
      abstract def store(data : Bytes, mask : Int32, ix : Int32) : Nil
      abstract def store_range(data : Bytes, mask : Int32, ix_start : Int32,
                               ix_end : Int32) : Nil
      abstract def stitch_to_previous_block(num_bytes : Int32, position : Int32,
                                            ringbuffer : Bytes,
                                            ringbuffer_mask : Int32) : Nil
      abstract def prepare_distance_cache(distance_cache : Slice(Int32)) : Nil
      abstract def find_longest_match(dict : EncoderDictionary, data : Bytes,
                                      ring_buffer_mask : Int32,
                                      distance_cache : Slice(Int32),
                                      cur_ix : Int32, max_length : Int32,
                                      max_backward : Int32,
                                      dictionary_distance : Int32,
                                      max_distance : Int32,
                                      sr : HasherSearchResult) : Nil
    end

    # hash_base.h:23 — Hash14.
    def self.hash14(data : Bytes, pos : Int32) : UInt32
      v = (data.to_unsafe + pos).as(Pointer(UInt32)).value
      (v &* StaticDict::HASH_MUL32) >> 18
    end

    # hash.h:147 — test a single hash_table item; updates `sr` if better.
    def self.test_static_dictionary_item?(dict : EncoderDictionary,
                                          len : Int32, word_idx : Int32,
                                          data : Bytes, pos : Int32,
                                          max_length : Int32,
                                          max_backward : Int32,
                                          max_distance : Int32,
                                          sr : HasherSearchResult) : Bool
      return false if len > max_length
      offset = dict.offsets_by_length.unsafe_fetch(len) &+ len &* word_idx
      matchlen = StaticDict.match_length(dict.data, offset, data, pos, len)
      return false if matchlen &+ dict.cutoff_transforms_count <= len ||
                      matchlen == 0
      cut = len &- matchlen
      transform_id = (cut << 2) &+
        ((dict.cutoff_transforms >> (cut &* 6)) & 0x3F).to_i32
      backward = max_backward &+ 1 &+ word_idx &+
                 (transform_id << dict.size_bits_by_length.unsafe_fetch(len))
      return false if backward > max_distance
      score = backward_reference_score(matchlen, backward)
      return false if score < sr.score
      sr.len = matchlen
      sr.len_code_delta = len &- matchlen
      sr.distance = backward
      sr.score = score
      true
    end

    # hash.h:186 — dictionary lookup gated by the hit/lookup ratio.
    def self.search_in_static_dictionary(dict : EncoderDictionary,
                                         common : HasherCommon,
                                         data : Bytes, pos : Int32,
                                         max_length : Int32,
                                         max_backward : Int32,
                                         max_distance : Int32,
                                         sr : HasherSearchResult,
                                         shallow : Bool) : Nil
      return if common.dict_num_matches < (common.dict_num_lookups >> 7)
      key = (hash14(data, pos) << 1).to_i32
      i = 0
      limit = shallow ? 1 : 2
      while i < limit
        common.dict_num_lookups &+= 1
        len = dict.hash_table_lengths.unsafe_fetch(key).to_i32
        if len != 0
          word_idx = dict.hash_table_words.unsafe_fetch(key).to_i32
          if test_static_dictionary_item?(dict, len, word_idx, data, pos,
                                          max_length, max_backward,
                                          max_distance, sr)
            common.dict_num_matches &+= 1
          end
        end
        key &+= 1
        i &+= 1
      end
    end

    # hash_longest_match_quickly_inc.h — one class parameterized the way C
    # instantiates H2/H3/H4/H54 (bucket bits / sweep bits / hash length /
    # dictionary use).
    class QuicklyHasher
      include Hasher

      getter buckets : Slice(UInt32)
      getter common : HasherCommon
      @bucket_bits : Int32
      @bucket_mask : Int32
      @bucket_sweep : Int32      # 1 << BUCKET_SWEEP_BITS
      @bucket_sweep_mask : Int32 # (sweep - 1) << 3
      @hash_len : Int32
      @use_dict : Bool

      def initialize(bucket_bits : Int32, sweep_bits : Int32,
                     hash_len : Int32, use_dict : Bool)
        @bucket_bits = bucket_bits
        @bucket_mask = (1 << bucket_bits) - 1
        @bucket_sweep = 1 << sweep_bits
        @bucket_sweep_mask = (@bucket_sweep - 1) << 3
        @hash_len = hash_len
        @use_dict = use_dict
        @buckets = Slice(UInt32).new(1 << bucket_bits)
        @common = HasherCommon.new
      end

      def self.h2 : QuicklyHasher
        new(16, 0, 5, true)
      end

      def self.h3 : QuicklyHasher
        new(16, 1, 5, false)
      end

      def self.h4 : QuicklyHasher
        new(17, 2, 5, true)
      end

      def self.h54 : QuicklyHasher
        new(20, 2, 7, false)
      end

      def hash_type_length : Int32
        8
      end

      def store_lookahead : Int32
        8
      end

      # hash_longest_match_quickly_inc.h:56
      def hash_bytes(data : Bytes, pos : Int32) : UInt32
        v = (data.to_unsafe + pos).as(Pointer(UInt64)).value
        (((v << ((8 &- @hash_len) &* 8)) &* K_HASH_MUL64) >>
         (64 &- @bucket_bits)).to_u32!
      end

      # hash_longest_match_quickly_inc.h:40
      def prepare(data : Bytes, one_shot : Bool, input_size : Int32) : Nil
        partial_prepare_threshold = @buckets.size >> 5
        if one_shot && input_size <= partial_prepare_threshold
          i = 0
          while i < input_size
            key = hash_bytes(data, i)
            if @bucket_sweep == 1
              @buckets[key] = 0
            else
              j = 0
              while j < @bucket_sweep
                @buckets[(key &+ (j << 3)) & @bucket_mask] = 0
                j += 1
              end
            end
            i += 1
          end
        else
          @buckets.fill(0)
        end
      end

      # hash_longest_match_quickly_inc.h:84
      def store(data : Bytes, mask : Int32, ix : Int32) : Nil
        key = hash_bytes(data, ix & mask)
        if @bucket_sweep == 1
          @buckets[key] = ix.to_u32!
        else
          off = ix & @bucket_sweep_mask
          @buckets[(key &+ off) & @bucket_mask] = ix.to_u32!
        end
      end

      def store_range(data : Bytes, mask : Int32, ix_start : Int32,
                      ix_end : Int32) : Nil
        i = ix_start
        while i < ix_end
          store(data, mask, i)
          i += 1
        end
      end

      # hash_longest_match_quickly_inc.h:107
      def stitch_to_previous_block(num_bytes : Int32, position : Int32,
                                   ringbuffer : Bytes,
                                   ringbuffer_mask : Int32) : Nil
        if num_bytes >= 7 && position >= 3
          store(ringbuffer, ringbuffer_mask, position - 3)
          store(ringbuffer, ringbuffer_mask, position - 2)
          store(ringbuffer, ringbuffer_mask, position - 1)
        end
      end

      # Quickly hashers do not use the distance cache heuristics.
      def prepare_distance_cache(distance_cache : Slice(Int32)) : Nil
      end

      # hash_longest_match_quickly_inc.h:128
      def find_longest_match(dict : EncoderDictionary, data : Bytes,
                             ring_buffer_mask : Int32,
                             distance_cache : Slice(Int32),
                             cur_ix : Int32, max_length : Int32,
                             max_backward : Int32,
                             dictionary_distance : Int32,
                             max_distance : Int32,
                             sr : HasherSearchResult) : Nil
        buckets = @buckets
        best_len_in = sr.len
        cur_ix_masked = cur_ix & ring_buffer_mask
        compare_char = data.unsafe_fetch(cur_ix_masked &+ best_len_in)
        key = hash_bytes(data, cur_ix_masked)
        min_score = sr.score
        best_score = sr.score
        best_len = best_len_in
        cached_backward = distance_cache.unsafe_fetch(0)
        prev_ix = cur_ix &- cached_backward

        sr.len_code_delta = 0
        if prev_ix < cur_ix && cached_backward <= max_backward
          prev_ix &= ring_buffer_mask
          if compare_char == data.unsafe_fetch(prev_ix &+ best_len)
            len = Enc.find_match_length_with_limit(data, prev_ix, cur_ix_masked,
                                               max_length)
            if len >= 4
              score = Enc.backward_reference_score_using_last_distance(len)
              if best_score < score
                sr.len = len
                sr.distance = cached_backward
                sr.score = score
                if @bucket_sweep == 1
                  buckets[key] = cur_ix.to_u32!
                  return
                else
                  best_len = len
                  best_score = score
                  compare_char = data.unsafe_fetch(cur_ix_masked &+ len)
                end
              end
            end
          end
        end

        if @bucket_sweep == 1
          prev_ix = buckets[key].to_i32
          buckets[key] = cur_ix.to_u32!
          backward = cur_ix &- prev_ix
          prev_ix &= ring_buffer_mask
          return if compare_char != data.unsafe_fetch(prev_ix &+ best_len_in)
          return if backward == 0 || backward > max_backward
          len = Enc.find_match_length_with_limit(data, prev_ix, cur_ix_masked,
                                             max_length)
          if len >= 4
            score = Enc.backward_reference_score(len, backward)
            if best_score < score
              sr.len = len
              sr.distance = backward
              sr.score = score
              return
            end
          end
        else
          keys = StaticArray(Int32, 4).new(0)
          i = 0
          while i < @bucket_sweep
            keys[i] = (key.to_i32! &+ (i << 3)) & @bucket_mask
            i &+= 1
          end
          key_out = keys[(cur_ix & @bucket_sweep_mask) >> 3]
          i = 0
          while i < @bucket_sweep
            prev_ix = buckets.unsafe_fetch(keys[i]).to_i32
            backward = cur_ix &- prev_ix
            prev_ix &= ring_buffer_mask
            i &+= 1
            next if compare_char != data.unsafe_fetch(prev_ix &+ best_len)
            next if backward == 0 || backward > max_backward
            len = Enc.find_match_length_with_limit(data, prev_ix, cur_ix_masked,
                                               max_length)
            if len >= 4
              score = Enc.backward_reference_score(len, backward)
              if best_score < score
                best_len = len
                sr.len = len
                compare_char = data.unsafe_fetch(cur_ix_masked &+ len)
                best_score = score
                sr.score = score
                sr.distance = backward
              end
            end
          end
          if @use_dict && min_score == sr.score
            Enc.search_in_static_dictionary(dict, @common, data, cur_ix_masked,
                                        max_length, dictionary_distance,
                                        max_distance, sr, true)
          end
          buckets[key_out] = cur_ix.to_u32!
          return
        end

        if @use_dict && min_score == sr.score
          Enc.search_in_static_dictionary(dict, @common, data, cur_ix_masked,
                                      max_length, dictionary_distance,
                                      max_distance, sr, true)
        end
      end
    end

    # Port of hash_longest_match_inc.h (H5, 32-bit hash) and
    # hash_longest_match64_inc.h (H6, 64-bit hash, 8-byte type length).
    # Bucket/block sizes come from HasherParams (ChooseHasher).
    class LongestMatchHasher
      include Hasher

      getter common : HasherCommon
      @bucket_bits : Int32
      @bucket_size : Int32
      @block_size : Int32
      @block_mask : UInt32
      @block_bits : Int32
      @num_last_distances_to_check : Int32
      @use_64 : Bool
      @num : Slice(UInt16)
      @buckets : Slice(UInt32)

      def initialize(bucket_bits : Int32, block_bits : Int32,
                     num_last_distances_to_check : Int32, use_64 : Bool)
        @bucket_bits = bucket_bits
        @bucket_size = 1 << bucket_bits
        @block_size = 1 << block_bits
        @block_mask = (@block_size - 1).to_u32!
        @block_bits = block_bits
        @num_last_distances_to_check = num_last_distances_to_check
        @use_64 = use_64
        @num = Slice(UInt16).new(@bucket_size)
        @buckets = Slice(UInt32).new(@bucket_size * @block_size)
        @common = HasherCommon.new
      end

      def hash_type_length : Int32
        @use_64 ? 8 : 4
      end

      def store_lookahead : Int32
        @use_64 ? 8 : 4
      end

      # hash_longest_match_inc.h:23 / hash_longest_match64_inc.h:24
      private def hash_bytes(data : Bytes, pos : Int32) : Int32
        key = if @use_64
                v = (data.to_unsafe + pos).as(Pointer(UInt64)).value
                hash_mul = K_HASH_MUL64 << (64 &- 5 &* 8)
                ((v &* hash_mul) >> (64 &- 15)).to_i32!
              else
                v = (data.to_unsafe + pos).as(Pointer(UInt32)).value
                ((v &* StaticDict::HASH_MUL32) >>
                 (32 &- @bucket_bits)).to_i32!
              end
        key
      end

      # hash_longest_match_inc.h:74
      def prepare(data : Bytes, one_shot : Bool, input_size : Int32) : Nil
        # Partial preparation is 100 times slower (per socket).
        partial_prepare_threshold = @bucket_size >> 6
        if one_shot && input_size <= partial_prepare_threshold
          i = 0
          while i < input_size
            @num[hash_bytes(data, i)] = 0
            i += 1
          end
        else
          @num.fill(0)
        end
      end

      # hash_longest_match_inc.h:104
      def store(data : Bytes, mask : Int32, ix : Int32) : Nil
        key = hash_bytes(data, ix & mask)
        # NB: index math must stay Int32 — UInt16 receiver type of num[] would
        # truncate (UInt16 &+ UInt32 evaluates in UInt16) and split buckets.
        minor_ix = @num.unsafe_fetch(key).to_i32! & @block_mask
        offset = minor_ix &+ (key << @block_bits)
        @num[key] = @num.unsafe_fetch(key) &+ 1
        @buckets[offset] = ix.to_u32!
      end

      # hash_longest_match_inc.h:116
      def store_range(data : Bytes, mask : Int32, ix_start : Int32,
                      ix_end : Int32) : Nil
        i = ix_start
        while i < ix_end
          store(data, mask, i)
          i += 1
        end
      end

      # hash_longest_match_inc.h:125
      def stitch_to_previous_block(num_bytes : Int32, position : Int32,
                                   ringbuffer : Bytes,
                                   ringbuffer_mask : Int32) : Nil
        if num_bytes >= hash_type_length - 1 && position >= 3
          store(ringbuffer, ringbuffer_mask, position - 3)
          store(ringbuffer, ringbuffer_mask, position - 2)
          store(ringbuffer, ringbuffer_mask, position - 1)
        end
      end

      # hash_longest_match_inc.h:139
      def prepare_distance_cache(distance_cache : Slice(Int32)) : Nil
        Enc.prepare_distance_cache(distance_cache,
                                   @num_last_distances_to_check)
      end

      # hash_longest_match_inc.h:156
      def find_longest_match(dict : EncoderDictionary, data : Bytes,
                             ring_buffer_mask : Int32,
                             distance_cache : Slice(Int32),
                             cur_ix : Int32, max_length : Int32,
                             max_backward : Int32,
                             dictionary_distance : Int32,
                             max_distance : Int32,
                             sr : HasherSearchResult) : Nil
        num = @num
        buckets = @buckets
        cur_ix_masked = cur_ix & ring_buffer_mask
        min_score = sr.score
        best_score = sr.score
        best_len = sr.len
        key = hash_bytes(data, cur_ix_masked)
        bucket_offset = (key << @block_bits).to_i32!
        sr.len = 0
        sr.len_code_delta = 0

        # Try last distance first.
        i = 0
        while i < @num_last_distances_to_check
          backward = distance_cache.unsafe_fetch(i)
          prev_ix = cur_ix &- backward
          i += 1
          next if prev_ix >= cur_ix || backward > max_backward
          prev_ix &= ring_buffer_mask
          break if cur_ix_masked &+ best_len > ring_buffer_mask
          if prev_ix &+ best_len > ring_buffer_mask ||
             data.unsafe_fetch(cur_ix_masked &+ best_len) !=
               data.unsafe_fetch(prev_ix &+ best_len)
            next
          end
          len = Enc.find_match_length_with_limit(data, prev_ix,
                                                 cur_ix_masked, max_length)
          if len >= 3 || (len == 2 && i <= 2)
            score = Enc.backward_reference_score_using_last_distance(len)
            if best_score < score
              score &-= Enc.backward_reference_penalty_using_last_distance(
                i - 1) if i != 1
              if best_score < score
                best_score = score
                best_len = len
                sr.len = best_len
                sr.distance = backward
                sr.score = best_score
              end
            end
          end
        end
        # We require matches of len > 4, so increase best_len to 3, so we
        # can compare 4 bytes all the time.
        best_len = 3 if best_len < 3

        num_key = num.unsafe_fetch(key)
        down = num_key.to_i32! > @block_size ? num_key.to_i32! - @block_size : 0
        i = num_key.to_i32!
        while i > down
          i -= 1
          # Int32 index math — see store() for the UInt16 truncation pitfall.
          prev_ix = buckets.unsafe_fetch(
            (i & @block_mask).to_i32! &+ bucket_offset).to_i32!
          backward = cur_ix &- prev_ix
          break if backward > max_backward
          prev_ix &= ring_buffer_mask
          break if cur_ix_masked &+ best_len > ring_buffer_mask
          if prev_ix &+ best_len > ring_buffer_mask ||
             read_u32(data, cur_ix_masked &+ best_len &- 3) !=
               read_u32(data, prev_ix &+ best_len &- 3)
            next
          end
          len = Enc.find_match_length_with_limit(data, prev_ix,
                                                 cur_ix_masked, max_length)
          if len >= 4
            score = Enc.backward_reference_score(len, backward)
            if best_score < score
              best_score = score
              best_len = len
              sr.len = best_len
              sr.distance = backward
              sr.score = best_score
            end
          end
        end
        buckets[(num_key.to_i32! & @block_mask) &+ bucket_offset] = cur_ix.to_u32!
        num[key] = num_key &+ 1

        if min_score == sr.score
          Enc.search_in_static_dictionary(dict, @common, data,
                                          cur_ix_masked, max_length,
                                          dictionary_distance, max_distance,
                                          sr, false)
        end
      end

      private def read_u32(data : Bytes, pos : Int32) : UInt32
        (data.to_unsafe + pos).as(Pointer(UInt32)).value
      end
    end

    # Port of hash_forgetful_chain_inc.h (H40/H41/H42 instantiations;
    # BUCKET_BITS 15, CAPPED_CHAINS 0).
    class ForgetfulChainHasher
      include Hasher

      getter common : HasherCommon
      @bucket_size : Int32
      @num_banks : Int32
      @bank_size : Int32
      @bank_mask : Int32
      @num_last_distances_to_check : Int32
      @max_hops : Int32
      @addr : Slice(UInt32)
      @head : Slice(UInt16)
      @tiny_hash : Slice(UInt8)
      @free_slot_idx : Slice(UInt16)
      @bank_delta : Slice(UInt16)
      @bank_next : Slice(UInt16)

      def initialize(num_last_distances_to_check : Int32, num_banks : Int32,
                     bank_bits : Int32, quality : Int32)
        @bucket_size = 1 << 15 # BUCKET_BITS
        @num_banks = num_banks
        @bank_size = 1 << bank_bits
        @bank_mask = @bank_size - 1
        @num_last_distances_to_check = num_last_distances_to_check
        @max_hops = (quality > 6 ? 7 : 8) << (quality - 4)
        @addr = Slice(UInt32).new(@bucket_size)
        @head = Slice(UInt16).new(@bucket_size)
        @tiny_hash = Slice(UInt8).new(65536)
        @free_slot_idx = Slice(UInt16).new(num_banks)
        @bank_delta = Slice(UInt16).new(num_banks * @bank_size)
        @bank_next = Slice(UInt16).new(num_banks * @bank_size)
        @common = HasherCommon.new
      end

      def self.h40(quality : Int32) : ForgetfulChainHasher
        new(4, 1, 16, quality)
      end

      def self.h41(quality : Int32) : ForgetfulChainHasher
        new(10, 1, 16, quality)
      end

      def self.h42(quality : Int32) : ForgetfulChainHasher
        new(16, 512, 9, quality)
      end

      def hash_type_length : Int32
        4
      end

      def store_lookahead : Int32
        4
      end

      # hash_forgetful_chain_inc.h:31
      private def hash_bytes(data : Bytes, pos : Int32) : Int32
        v = (data.to_unsafe + pos).as(Pointer(UInt32)).value
        ((v &* StaticDict::HASH_MUL32) >> (32 &- 15)).to_i32!
      end

      # hash_forgetful_chain_inc.h:93
      def prepare(data : Bytes, one_shot : Bool, input_size : Int32) : Nil
        partial_prepare_threshold = @bucket_size >> 6
        if one_shot && input_size <= partial_prepare_threshold
          i = 0
          while i < input_size
            bucket = hash_bytes(data, i)
            # See InitEmpty comment.
            @addr[bucket] = 0xCCCCCCCC_u32
            @head[bucket] = 0xCCCC
            i += 1
          end
        else
          # Fill addr with 0xCCCCCCCC: because of wrapping, the position
          # processed by the hasher never reaches 3GB + 64M, so every new
          # chain terminates after the first node.
          @addr.fill(0xCCCCCCCC_u32)
          @head.fill(0)
        end
        @tiny_hash.fill(0)
        @free_slot_idx.fill(0)
      end

      # hash_forgetful_chain_inc.h:133
      def store(data : Bytes, mask : Int32, ix : Int32) : Nil
        key = hash_bytes(data, ix & mask)
        bank = key & (@num_banks - 1)
        idx = @free_slot_idx.unsafe_fetch(bank) & @bank_mask
        @free_slot_idx[bank] = @free_slot_idx.unsafe_fetch(bank) &+ 1
        # C: size_t delta = ix - addr[key] (wraps when addr is the sentinel).
        delta = (ix.to_u64! &- @addr.unsafe_fetch(key))
        delta = 0xFFFF_u64 if delta > 0xFFFF
        @tiny_hash[ix & 0xFFFF] = key.to_u8!
        slot = (bank &* @bank_size) &+ idx
        @bank_delta[slot] = delta.to_u16!
        @bank_next[slot] = @head.unsafe_fetch(key)
        @addr[key] = ix.to_u32!
        @head[key] = idx.to_u16!
      end

      # hash_forgetful_chain_inc.h:151
      def store_range(data : Bytes, mask : Int32, ix_start : Int32,
                      ix_end : Int32) : Nil
        i = ix_start
        while i < ix_end
          store(data, mask, i)
          i += 1
        end
      end

      # hash_forgetful_chain_inc.h:161
      def stitch_to_previous_block(num_bytes : Int32, position : Int32,
                                   ringbuffer : Bytes,
                                   ringbuffer_mask : Int32) : Nil
        if num_bytes >= hash_type_length - 1 && position >= 3
          store(ringbuffer, ringbuffer_mask, position - 3)
          store(ringbuffer, ringbuffer_mask, position - 2)
          store(ringbuffer, ringbuffer_mask, position - 1)
        end
      end

      # hash_forgetful_chain_inc.h:175
      def prepare_distance_cache(distance_cache : Slice(Int32)) : Nil
        Enc.prepare_distance_cache(distance_cache,
                                   @num_last_distances_to_check)
      end

      # hash_forgetful_chain_inc.h:193
      def find_longest_match(dict : EncoderDictionary, data : Bytes,
                             ring_buffer_mask : Int32,
                             distance_cache : Slice(Int32),
                             cur_ix : Int32, max_length : Int32,
                             max_backward : Int32,
                             dictionary_distance : Int32,
                             max_distance : Int32,
                             sr : HasherSearchResult) : Nil
        cur_ix_masked = cur_ix & ring_buffer_mask
        min_score = sr.score
        best_score = sr.score
        best_len = sr.len
        key = hash_bytes(data, cur_ix_masked)
        tiny_hash = key.to_u8!
        sr.len = 0
        sr.len_code_delta = 0

        # Try last distance first.
        i = 0
        while i < @num_last_distances_to_check
          backward = distance_cache.unsafe_fetch(i)
          prev_ix = cur_ix &- backward
          i += 1
          # For distance code 0 we want to consider 2-byte matches.
          next if i - 1 > 0 &&
                  @tiny_hash.unsafe_fetch(prev_ix & 0xFFFF) != tiny_hash
          next if prev_ix >= cur_ix || backward > max_backward
          prev_ix &= ring_buffer_mask
          len = Enc.find_match_length_with_limit(data, prev_ix,
                                                 cur_ix_masked, max_length)
          if len >= 2
            score = Enc.backward_reference_score_using_last_distance(len)
            if best_score < score
              score &-= Enc.backward_reference_penalty_using_last_distance(
                i - 1) if i != 1
              if best_score < score
                best_score = score
                best_len = len
                sr.len = best_len
                sr.distance = backward
                sr.score = best_score
              end
            end
          end
        end
        best_len = 3 if best_len < 3

        bank = key & (@num_banks - 1)
        backward = 0_u64
        hops = @max_hops
        delta = cur_ix.to_u64! &- @addr.unsafe_fetch(key)
        slot = @head.unsafe_fetch(key).to_i32
        while hops > 0
          hops -= 1
          last = slot
          backward &+= delta
          break if backward > max_backward
          prev_ix = (cur_ix &- backward.to_i32!) & ring_buffer_mask
          slot = @bank_next.unsafe_fetch((bank &* @bank_size) &+
                                         last).to_i32
          delta = @bank_delta.unsafe_fetch((bank &* @bank_size) &+
                                           last).to_u64
          if cur_ix_masked &+ best_len > ring_buffer_mask ||
             prev_ix &+ best_len > ring_buffer_mask ||
             read_u32(data, cur_ix_masked &+ best_len &- 3) !=
               read_u32(data, prev_ix &+ best_len &- 3)
            next
          end
          len = Enc.find_match_length_with_limit(data, prev_ix,
                                                 cur_ix_masked, max_length)
          if len >= 4
            score = Enc.backward_reference_score(len, backward.to_i32!)
            if best_score < score
              best_score = score
              best_len = len
              sr.len = best_len
              sr.distance = backward.to_i32!
              sr.score = best_score
            end
          end
        end
        store(data, ring_buffer_mask, cur_ix)

        if sr.score == min_score
          Enc.search_in_static_dictionary(dict, @common, data,
                                          cur_ix_masked, max_length,
                                          dictionary_distance, max_distance,
                                          sr, false)
        end
      end

      private def read_u32(data : Bytes, pos : Int32) : UInt32
        (data.to_unsafe + pos).as(Pointer(UInt32)).value
      end
    end

    # hash.h:212 — a backward match candidate (dictionary matches also carry
    # a length code in the low 5 bits).
    struct BackwardMatch
      property distance : UInt32
      property length_and_code : UInt32

      def initialize(@distance = 0_u32, @length_and_code = 0_u32)
      end

      def self.init_match(distance : Int32, length : Int32) : BackwardMatch
        new(distance.to_u32!, (length << 5).to_u32!)
      end

      def self.init_dictionary_match(distance : Int32, length : Int32,
                                     length_code : Int32) : BackwardMatch
        new(distance.to_u32!,
            ((length << 5) | length_code).to_u32!)
      end

      def length : Int32
        @length_and_code >> 5
      end

      # 0 means "same as length".
      def length_code : Int32
        code = @length_and_code & 31
        code == 0 ? length : code
      end
    end

    # Port of hash_to_binary_tree_inc.h (H10 instantiation: BUCKET_BITS 17,
    # MAX_TREE_COMP_LENGTH 128, MAX_TREE_SEARCH_DEPTH 64).
    # Each hash bucket holds a binary tree of sequences sharing the 4-byte
    # hash, lexicographically sorted and max-heap by start position.
    class BinaryTreeHasher
      MAX_TREE_COMP_LENGTH = 128
      MAX_TREE_SEARCH_DEPTH = 64
      MAX_NUM_MATCHES_H10 = MAX_TREE_SEARCH_DEPTH + 64

      getter common : HasherCommon
      @window_mask : Int32
      @invalid_pos : Int32
      @buckets : Slice(Int32)
      @forest : Slice(Int32)

      def initialize(lgwin : Int32, num_nodes : Int32)
        # C: one_shot with input_size < 2^lgwin shrinks the forest.
        @window_mask = (1 << lgwin) - 1
        # (uint32_t)(0 - window_mask) as signed.
        @invalid_pos = -@window_mask
        @buckets = Slice(Int32).new(1 << 17, @invalid_pos)
        @forest = Slice(Int32).new(2 * num_nodes)
        @common = HasherCommon.new
      end

      def hash_type_length : Int32
        4
      end

      def store_lookahead : Int32
        MAX_TREE_COMP_LENGTH
      end

      # hash_to_binary_tree_inc.h:27
      private def hash_bytes(data : Bytes, pos : Int32) : Int32
        v = (data.to_unsafe + pos).as(Pointer(UInt32)).value
        ((v &* StaticDict::HASH_MUL32) >> (32 &- 17)).to_i32!
      end

      # hash_to_binary_tree_inc.h:67
      def prepare(data : Bytes, one_shot : Bool, input_size : Int32) : Nil
        @buckets.fill(@invalid_pos)
      end

      def left_child_index(pos : Int32) : Int32
        2 &* (pos & @window_mask)
      end

      def right_child_index(pos : Int32) : Int32
        2 &* (pos & @window_mask) &+ 1
      end

      # hash_to_binary_tree_inc.h:114 — stores the hash of the next 4 bytes
      # and, in a single tree traversal, searches the bucket's tree for
      # matches and re-roots it at the current position. Returns
      # {best_len, match_count}; matches/mpos are unused when matches is nil.
      def store_and_find_matches(data : Bytes, cur_ix : Int32,
                                 ring_buffer_mask : Int32, max_length : Int32,
                                 max_backward : Int32, best_len_in : Int32,
                                 matches : Slice(BackwardMatch)?,
                                 mpos_in : Int32) : {Int32, Int32}
        cur_ix_masked = cur_ix & ring_buffer_mask
        max_comp_len = Math.min(max_length, MAX_TREE_COMP_LENGTH)
        should_reroot_tree = max_length >= MAX_TREE_COMP_LENGTH
        key = hash_bytes(data, cur_ix_masked)
        buckets = @buckets
        forest = @forest
        prev_ix = buckets.unsafe_fetch(key)
        best_len = best_len_in
        mpos = mpos_in
        # Forest index of the rightmost node of the left subtree of the new
        # root, and the leftmost node of the right subtree.
        node_left = left_child_index(cur_ix)
        node_right = right_child_index(cur_ix)
        best_len_left = 0
        best_len_right = 0
        buckets[key] = cur_ix if should_reroot_tree
        depth_remaining = MAX_TREE_SEARCH_DEPTH
        loop do
          backward = cur_ix &- prev_ix
          prev_ix_masked = prev_ix & ring_buffer_mask
          if backward == 0 || backward > max_backward || depth_remaining == 0
            if should_reroot_tree
              forest[node_left] = @invalid_pos
              forest[node_right] = @invalid_pos
            end
            break
          end
          cur_len = Math.min(best_len_left, best_len_right)
          len = cur_len &+ Enc.find_match_length_with_limit(
            data, cur_ix_masked &+ cur_len, prev_ix_masked &+ cur_len,
            max_length &- cur_len)
          if matches && len > best_len
            best_len = len
            matches[mpos] = BackwardMatch.init_match(backward, len)
            mpos += 1
          end
          if len >= max_comp_len
            if should_reroot_tree
              forest[node_left] = forest.unsafe_fetch(
                left_child_index(prev_ix))
              forest[node_right] = forest.unsafe_fetch(
                right_child_index(prev_ix))
            end
            break
          end
          if data.unsafe_fetch(cur_ix_masked &+ len) >
             data.unsafe_fetch(prev_ix_masked &+ len)
            best_len_left = len
            forest[node_left] = prev_ix if should_reroot_tree
            node_left = right_child_index(prev_ix)
            prev_ix = forest.unsafe_fetch(node_left)
          else
            best_len_right = len
            forest[node_right] = prev_ix if should_reroot_tree
            node_right = left_child_index(prev_ix)
            prev_ix = forest.unsafe_fetch(node_right)
          end
          depth_remaining -= 1
        end
        {best_len, mpos}
      end

      # hash_to_binary_tree_inc.h:202 — all matches at cur_ix, sorted by
      # strictly increasing length and non-strictly increasing distance.
      def find_all_matches(dict : EncoderDictionary, data : Bytes,
                           ring_buffer_mask : Int32, cur_ix : Int32,
                           max_length : Int32, max_backward : Int32,
                           dictionary_distance : Int32, params : Params,
                           matches : Slice(BackwardMatch)) : Int32
        mpos = 0
        cur_ix_masked = cur_ix & ring_buffer_mask
        best_len = 1
        short_match_max_backward =
          params.quality != HQ_ZOPFLIFICATION_QUALITY ? 16 : 64
        stop = cur_ix - short_match_max_backward
        stop = 0 if cur_ix < short_match_max_backward
        i = cur_ix - 1
        while i > stop && best_len <= 2
          prev_ix = i
          backward = cur_ix - prev_ix
          break if backward > max_backward
          prev_ix &= ring_buffer_mask
          if data.unsafe_fetch(cur_ix_masked) == data.unsafe_fetch(prev_ix) &&
             data.unsafe_fetch(cur_ix_masked &+ 1) ==
               data.unsafe_fetch(prev_ix &+ 1)
            len = Enc.find_match_length_with_limit(data, prev_ix,
                                                   cur_ix_masked, max_length)
            if len > best_len
              best_len = len
              matches[mpos] = BackwardMatch.init_match(backward, len)
              mpos += 1
            end
          end
          i -= 1
        end
        if best_len < max_length
          best_len, mpos = store_and_find_matches(
            data, cur_ix, ring_buffer_mask, max_length, max_backward,
            best_len, matches, mpos)
        end
        dict_matches = Slice(UInt32).new(
          MAX_STATIC_DICTIONARY_MATCH_LEN + 1, K_INVALID_MATCH)
        minlen = Math.max(4, best_len + 1)
        if Enc.find_all_static_dictionary_matches(
            dict, data, cur_ix_masked, minlen, max_length, dict_matches)
          maxlen = Math.min(MAX_STATIC_DICTIONARY_MATCH_LEN, max_length)
          l = minlen
          while l <= maxlen
            dict_id = dict_matches.unsafe_fetch(l)
            if dict_id < K_INVALID_MATCH
              distance = dictionary_distance &+ (dict_id >> 5).to_i32 &+ 1
              if distance <= params.dist.max_distance
                matches[mpos] = BackwardMatch.init_dictionary_match(
                  distance, l, (dict_id & 31).to_i32)
                mpos += 1
              end
            end
            l += 1
          end
        end
        mpos
      end

      # hash_to_binary_tree_inc.h:271
      def store(data : Bytes, mask : Int32, ix : Int32) : Nil
        # Maximum distance is window size - 16, see section 9.1 of the spec.
        max_backward = @window_mask &- Brotli::WINDOW_GAP &+ 1
        store_and_find_matches(data, ix, mask, MAX_TREE_COMP_LENGTH,
                               max_backward, 0, nil, 0)
      end

      # hash_to_binary_tree_inc.h:280
      def store_range(data : Bytes, mask : Int32, ix_start : Int32,
                      ix_end : Int32) : Nil
        i = ix_start
        j = ix_start
        i = ix_end - 63 if ix_start &+ 63 <= ix_end
        if ix_start &+ 512 <= i
          while j < i
            store(data, mask, j)
            j += 8
          end
        end
        while i < ix_end
          store(data, mask, i)
          i += 1
        end
      end

      # hash_to_binary_tree_inc.h:298
      def stitch_to_previous_block(num_bytes : Int32, position : Int32,
                                   ringbuffer : Bytes,
                                   ringbuffer_mask : Int32) : Nil
        if num_bytes >= hash_type_length - 1 &&
           position >= MAX_TREE_COMP_LENGTH
          # Store the last MAX_TREE_COMP_LENGTH - 1 positions in the hasher.
          i_start = position - MAX_TREE_COMP_LENGTH + 1
          i_end = Math.min(position, i_start &+ num_bytes)
          i = i_start
          while i < i_end
            # Don't look further back from the start of the next block than
            # the window size, otherwise we could access overwritten areas.
            max_backward = @window_mask &- Math.max(
              Brotli::WINDOW_GAP &- 1, position &- i)
            store_and_find_matches(ringbuffer, i, ringbuffer_mask,
                                   MAX_TREE_COMP_LENGTH, max_backward, 0,
                                   nil, 0)
            i += 1
          end
        end
      end
    end
  end
end
