# Port of c/enc/backward_references.{c,h} + backward_references_inc.h:
# the greedy/lazy backward-reference loop used by qualities 2+ (the
# non-Zopfli path). Base64 regions and compound/contextual dictionaries
# are out of scope; gap = 0 and dict_id = 0 as in the default encoder.
# Upstream: 42a2ed4.

module Brotli
  module Enc
    # backward_references.c:117 — intermediate distance code (0..15 short
    # codes, or distance + NUM_DISTANCE_SHORT_CODES - 1).
    def self.compute_distance_code(distance : Int32, max_distance : Int32,
                                   dist_cache : Slice(Int32)) : Int32
      if distance <= max_distance
        distance_plus_3 = distance &+ 3
        offset0 = distance_plus_3 &- dist_cache.unsafe_fetch(0)
        offset1 = distance_plus_3 &- dist_cache.unsafe_fetch(1)
        if distance == dist_cache.unsafe_fetch(0)
          return 0
        elsif distance == dist_cache.unsafe_fetch(1)
          return 1
        elsif offset0 >= 0 && offset0 < 7
          return (0x9750468 >> (4 &* offset0)) & 0xF
        elsif offset1 >= 0 && offset1 < 7
          return (0xFDB1ACE >> (4 &* offset1)) & 0xF
        elsif distance == dist_cache.unsafe_fetch(2)
          return 2
        elsif distance == dist_cache.unsafe_fetch(3)
          return 3
        end
      end
      distance &+ Brotli::NUM_DISTANCE_SHORT_CODES &- 1
    end

    # quality.h:116
    def self.literal_spree_length_for_sparse_search(quality : Int32) : Int32
      quality < 9 ? 64 : 512
    end

    # backward_references_inc.h:10 — returns the appended commands plus the
    # number of literals in them; `last_insert_len` carries the pending
    # insert run between calls (mutated dist_cache in place, as in C).
    # position_offset is C's params->stream_offset: how much data precedes
    # the ring buffer (fragment-relative encoding passes frag_pos), so that
    # static-dictionary distances base off the ABSOLUTE position — the
    # decoder resolves dict references only for distances beyond
    # min(abs_pos, max_backward_limit).
    def self.create_backward_references(num_bytes : Int32, position : Int32,
                                        position_offset : Int32,
                                        data : Bytes, mask : Int32,
                                        params : Params,
                                        hasher : QuicklyHasher,
                                        dict : EncoderDictionary,
                                        dist_cache : Slice(Int32),
                                        last_insert_len : Int32,
                                        commands : Array(Command)) : {Int32, Int32}
      # Set maximum distance, see section 9.1 of the spec.
      max_backward_limit = (1 << params.lgwin) - Brotli::WINDOW_GAP

      insert_length = last_insert_len
      pos_end = position &+ num_bytes
      store_end = num_bytes >= 8 ? position &+ num_bytes &- 8 &+ 1 : position

      # For speed-up heuristics for random data.
      random_heuristics_window_size =
        literal_spree_length_for_sparse_search(params.quality)
      apply_random_heuristics = position &+ random_heuristics_window_size

      # Minimum score to accept a backward reference.
      min_score = (SCORE_BASE &+ 100).to_u64!

      hasher.prepare_distance_cache(dist_cache)
      num_literals = 0
      pos = position

      while pos &+ 8 < pos_end
        max_length = pos_end &- pos
        max_distance = Math.min(pos, max_backward_limit)
        dictionary_start = Math.min(pos &+ position_offset,
                                    max_backward_limit)
        sr = HasherSearchResult.new
        sr.score = min_score
        hasher.find_longest_match(dict, data, mask, dist_cache, pos,
                                  max_length, max_distance, dictionary_start,
                                  params.dist.max_distance.to_i32!, sr)
        if sr.score > min_score
          # Found a match. Let's look for something even better ahead.
          delayed_backward_references_in_row = 0
          max_length &-= 1
          loop do
            cost_diff_lazy = 175
            sr2 = HasherSearchResult.new
            sr2.len = params.quality < MIN_QUALITY_FOR_EXTENSIVE_REFERENCE_SEARCH ?
              Math.min(sr.len &- 1, max_length) : 0
            sr2.score = min_score
            max_distance = Math.min(pos &+ 1, max_backward_limit)
            dictionary_start = Math.min(pos &+ 1 &+ position_offset,
                                        max_backward_limit)
            hasher.find_longest_match(dict, data, mask, dist_cache, pos &+ 1,
                                      max_length, max_distance,
                                      dictionary_start,
                                      params.dist.max_distance.to_i32!, sr2)
            if sr2.score >= sr.score &+ cost_diff_lazy
              # Ok, let's just write one byte for now and start a match
              # from the next byte.
              pos &+= 1
              insert_length &+= 1
              sr = sr2
              delayed_backward_references_in_row &+= 1
              break unless delayed_backward_references_in_row < 4 &&
                            pos &+ 8 < pos_end
              max_length &-= 1
              next
            end
            break
          end
          apply_random_heuristics =
            pos &+ 2 &* sr.len &+ random_heuristics_window_size
          dictionary_start = Math.min(pos &+ position_offset,
                                      max_backward_limit)
          # The first 16 codes are special short-codes, and the minimum
          # offset is 1.
          distance_code = compute_distance_code(sr.distance,
                                                dictionary_start, dist_cache)
          if sr.distance <= dictionary_start && distance_code > 0
            dist_cache[3] = dist_cache[2]
            dist_cache[2] = dist_cache[1]
            dist_cache[1] = dist_cache[0]
            dist_cache[0] = sr.distance
            hasher.prepare_distance_cache(dist_cache)
          end
          commands << Command.new(insert_length, sr.len, sr.len_code_delta,
                                  distance_code.to_u64, params.dist)
          num_literals &+= insert_length
          insert_length = 0
          # Put the hash keys into the table, if there are enough bytes
          # left. Avoid hash poisoning with RLE data.
          range_start = pos &+ 2
          range_end = Math.min(pos &+ sr.len, store_end)
          if sr.distance < (sr.len >> 2)
            range_start = Math.min(range_end, Math.max(
              range_start, pos &+ sr.len &- (sr.distance << 2)))
          end
          hasher.store_range(data, mask, range_start, range_end)
          pos &+= sr.len
        else
          insert_length &+= 1
          pos &+= 1
          # If we have not seen matches for a long time, we can skip some
          # match lookups.
          if pos > apply_random_heuristics
            if pos > apply_random_heuristics &+
                      4 &* random_heuristics_window_size
              # Going through uncompressible data, jump.
              margin = Math.max(8 - 1, 4) # StoreLookahead() == 8
              pos_jump = Math.min(pos &+ 16, pos_end &- margin)
              while pos < pos_jump
                hasher.store(data, mask, pos)
                insert_length &+= 4
                pos &+= 4
              end
            else
              margin = Math.max(8 - 1, 2)
              pos_jump = Math.min(pos &+ 8, pos_end &- margin)
              while pos < pos_jump
                hasher.store(data, mask, pos)
                insert_length &+= 2
                pos &+= 2
              end
            end
          end
        end
      end

      insert_length &+= pos_end &- pos
      {insert_length, num_literals}
    end
  end
end
