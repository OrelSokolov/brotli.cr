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
            len = find_match_length_with_limit(data, prev_ix, cur_ix_masked,
                                               max_length)
            if len >= 4
              score = backward_reference_score_using_last_distance(len)
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
          len = find_match_length_with_limit(data, prev_ix, cur_ix_masked,
                                             max_length)
          if len >= 4
            score = backward_reference_score(len, backward)
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
            keys[i] = (key &+ (i << 3)) & @bucket_mask
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
            len = find_match_length_with_limit(data, prev_ix, cur_ix_masked,
                                               max_length)
            if len >= 4
              score = backward_reference_score(len, backward)
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
            search_in_static_dictionary(dict, @common, data, cur_ix_masked,
                                        max_length, dictionary_distance,
                                        max_distance, sr, true)
          end
          buckets[key_out] = cur_ix.to_u32!
          return
        end

        if @use_dict && min_score == sr.score
          search_in_static_dictionary(dict, @common, data, cur_ix_masked,
                                      max_length, dictionary_distance,
                                      max_distance, sr, true)
        end
      end
    end
  end
end
