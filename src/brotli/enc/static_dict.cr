# Port of c/enc/static_dict.{c,h}: static-dictionary match search for the
# encoder (BrotliFindAllStaticDictionaryMatches). Upstream: 42a2ed4.
#
# All data reads are data[pos + k]; `data` must be readable through
# pos + max_length (+ slack), i.e. the ring buffer, not just the block.

module Brotli
  module Enc
    # static_dict.h:21
    K_INVALID_MATCH = 0xFFFFFFF_u32
    # hash.h (BROTLI_MAX_STATIC_DICTIONARY_MATCH_LEN).
    MAX_STATIC_DICTIONARY_MATCH_LEN = 37

    # hash_base.h:19/21 — hash multipliers (K_HASH_MUL32 lives in
    # compress_fragment.cr as UInt64 for the fragment hashers).
    K_HASH_MUL64 = 0x1FE35A7BD3579BD3_u64

    module StaticDict
      HASH_MUL32 = 0x1E35A7BD_u32

      # hash_base.h:31 — Hash15 over 4 bytes at data[pos].
      def self.hash15(data : Bytes, pos : Int32) : UInt32
        v = (data.to_unsafe + pos).as(Pointer(UInt32)).value
        (v &* HASH_MUL32) >> 17
      end

      # find_match_length between two DIFFERENT buffers (dictionary word and
      # ring buffer); C FindMatchLengthWithLimit with two pointers.
      private def self.match_length(dict : Bytes, d : Int32, data : Bytes,
                                    s : Int32, limit : Int32) : Int32
        base = d
        l = limit
        while l >= 8
          x = (dict.to_unsafe + d).as(Pointer(UInt64)).value ^
              (data.to_unsafe + s).as(Pointer(UInt64)).value
          if x != 0
            return (d &- base) &+ (x.trailing_zeros_count >> 3)
          end
          d &+= 8
          s &+= 8
          l &-= 8
        end
        while l > 0 && dict.unsafe_fetch(d) == data.unsafe_fetch(s)
          l &-= 1
          d &+= 1
          s &+= 1
        end
        d &- base
      end

      # static_dict.c:20
      private def self.add_match(distance : Int32, len : Int32, len_code : Int32,
                                 matches : Slice(UInt32)) : Nil
        match = ((distance.to_u32! << 5) &+ len_code.to_u32!)
        matches[len] = matches[len].min(match)
      end

      # static_dict.c:26
      private def self.dict_match_length(dict : EncoderDictionary,
                                         data : Bytes, pos : Int32,
                                         id : Int32, len : Int32,
                                         maxlen : Int32) : Int32
        offset = dict.offsets_by_length.unsafe_fetch(len) &+ len &* id
        match_length(dict.data, offset, data, pos, Math.min(len, maxlen))
      end

      # static_dict.c:36 — is the dictionary word (len/transform/idx) a
      # prefix of data[pos, max_length]?
      private def self.dict_is_match?(dict : EncoderDictionary, w_len : Int32,
                                      w_transform : Int32, w_idx : Int32,
                                      data : Bytes, pos : Int32,
                                      max_length : Int32) : Bool
        return false if w_len > max_length
        offset = dict.offsets_by_length.unsafe_fetch(w_len) &+
                 w_len &* w_idx
        dictp = dict.data
        if w_transform == 0
          match_length(dictp, offset, data, pos, w_len) == w_len
        elsif w_transform == 10
          # Uppercase-first; only ASCII uppercase words in the LUT.
          c0 = dictp.unsafe_fetch(offset)
          c0 >= 0x61 && c0 <= 0x7A &&
            (c0 ^ 32) == data.unsafe_fetch(pos) &&
            match_length(dictp, offset &+ 1, data, pos &+ 1,
                         w_len &- 1) == w_len &- 1
        else
          # Uppercase-all; only ASCII uppercase words in the LUT.
          i = 0
          while i < w_len
            c = dictp.unsafe_fetch(offset &+ i)
            if c >= 0x61 && c <= 0x7A
              return false if (c ^ 32) != data.unsafe_fetch(pos &+ i)
            else
              return false if c != data.unsafe_fetch(pos &+ i)
            end
            i += 1
          end
          true
        end
      end

      # static_dict.c:72 — the whole match/transform chain. `matches` holds
      # K_INVALID_MATCH on entry for every len. Returns has_found_match.
      def self.find_all_static_dictionary_matches(
          dict : EncoderDictionary, data : Bytes, pos : Int32,
          min_length : Int32, max_length : Int32,
          matches : Slice(UInt32)) : Bool
        has_found_match = false

        # Main bucket walk over Hash15(data).
        offset = dict.buckets.unsafe_fetch(hash15(data, pos)).to_i32
        end_ = offset == 0
        until end_
          w_raw_len = dict.dict_words_len.unsafe_fetch(offset).to_i32
          l = w_raw_len & 0x1F
          n = 1_i32 << dict.size_bits_by_length.unsafe_fetch(l)
          id = dict.dict_words_idx.unsafe_fetch(offset).to_i32
          w_transform = dict.dict_words_transform.unsafe_fetch(offset).to_i32
          offset &+= 1
          end_ = (w_raw_len & 0x80) != 0
          if w_transform == 0
            matchlen = dict_match_length(dict, data, pos, id, l, max_length)
            # Transform "" + IDENTITY + ""
            if matchlen == l
              add_match(id, l, l, matches)
              has_found_match = true
            end
            # "" + OMIT_LAST_1 + "" and "" + OMIT_LAST_1 + "ing "
            if matchlen >= l &- 1
              add_match(id &+ 12 &* n, l &- 1, l, matches)
              if l &+ 2 < max_length &&
                 data.unsafe_fetch(pos &+ l &- 1) == 0x69_u8 &&
                 data.unsafe_fetch(pos &+ l) == 0x6E_u8 &&
                 data.unsafe_fetch(pos &+ l &+ 1) == 0x67_u8 &&
                 data.unsafe_fetch(pos &+ l &+ 2) == 0x20_u8
                add_match(id &+ 49 &* n, l &+ 3, l, matches)
              end
              has_found_match = true
            end
            # "" + OMIT_LAST_# + "" (# = 2..9)
            minlen = min_length
            minlen = Math.max(minlen, l &- 9) if l > 9
            maxlen = Math.min(matchlen, l &- 2)
            len = minlen
            while len <= maxlen
              cut = l &- len
              transform_id = (cut << 2) &+
                ((dict.cutoff_transforms >> (cut &* 6)) & 0x3F).to_i32
              add_match(id &+ transform_id &* n, len, l, matches)
              has_found_match = true
              len += 1
            end
            next if matchlen < l || l &+ 6 >= max_length
            # "" + IDENTITY + <suffix>
            sp = pos &+ l
            s0 = data.unsafe_fetch(sp)
            s1 = data.unsafe_fetch(sp &+ 1)
            s2 = data.unsafe_fetch(sp &+ 2)
            if s0 == 0x20_u8 # ' '
              add_match(id &+ n, l &+ 1, l, matches)
              if s1 == 0x61_u8 # 'a'
                if s2 == 0x20_u8
                  add_match(id &+ 28 &* n, l &+ 3, l, matches)
                elsif s2 == 0x73_u8 # 's'
                  if data.unsafe_fetch(sp &+ 3) == 0x20_u8
                    add_match(id &+ 46 &* n, l &+ 4, l, matches)
                  end
                elsif s2 == 0x74_u8 # 't'
                  if data.unsafe_fetch(sp &+ 3) == 0x20_u8
                    add_match(id &+ 60 &* n, l &+ 4, l, matches)
                  end
                elsif s2 == 0x6E_u8 # 'n'
                  if data.unsafe_fetch(sp &+ 3) == 0x64_u8 &&
                     data.unsafe_fetch(sp &+ 4) == 0x20_u8
                    add_match(id &+ 10 &* n, l &+ 5, l, matches)
                  end
                end
              elsif s1 == 0x62_u8 # 'b'
                if s2 == 0x79_u8 && data.unsafe_fetch(sp &+ 3) == 0x20_u8
                  add_match(id &+ 38 &* n, l &+ 4, l, matches)
                end
              elsif s1 == 0x69_u8 # 'i'
                if s2 == 0x6E_u8
                  if data.unsafe_fetch(sp &+ 3) == 0x20_u8
                    add_match(id &+ 16 &* n, l &+ 4, l, matches)
                  end
                elsif s2 == 0x73_u8
                  if data.unsafe_fetch(sp &+ 3) == 0x20_u8
                    add_match(id &+ 47 &* n, l &+ 4, l, matches)
                  end
                end
              elsif s1 == 0x66_u8 # 'f'
                if s2 == 0x6F_u8 # 'o'
                  if data.unsafe_fetch(sp &+ 3) == 0x72_u8 &&
                     data.unsafe_fetch(sp &+ 4) == 0x20_u8
                    add_match(id &+ 25 &* n, l &+ 5, l, matches)
                  end
                elsif s2 == 0x72_u8 # 'r'
                  if data.unsafe_fetch(sp &+ 3) == 0x6F_u8 &&
                     data.unsafe_fetch(sp &+ 4) == 0x6D_u8 &&
                     data.unsafe_fetch(sp &+ 5) == 0x20_u8
                    add_match(id &+ 37 &* n, l &+ 6, l, matches)
                  end
                end
              elsif s1 == 0x6F_u8 # 'o'
                if s2 == 0x66_u8 # 'f'
                  if data.unsafe_fetch(sp &+ 3) == 0x20_u8
                    add_match(id &+ 8 &* n, l &+ 4, l, matches)
                  end
                elsif s2 == 0x6E_u8 # 'n'
                  if data.unsafe_fetch(sp &+ 3) == 0x20_u8
                    add_match(id &+ 45 &* n, l &+ 4, l, matches)
                  end
                end
              end
            elsif s0 == 0x22_u8 # '"'
              add_match(id &+ 19 &* n, l &+ 1, l, matches)
              add_match(id &+ 21 &* n, l &+ 2, l, matches) if s1 == 0x3E_u8 # '>'
            elsif s0 == 0x2E_u8 # '.'
              add_match(id &+ 20 &* n, l &+ 1, l, matches)
              if s1 == 0x20_u8
                add_match(id &+ 31 &* n, l &+ 2, l, matches)
                if s2 == 0x54_u8 && data.unsafe_fetch(sp &+ 3) == 0x68_u8 # 'T','h'
                  c4 = data.unsafe_fetch(sp &+ 4)
                  if c4 == 0x65_u8 # 'e'
                    if data.unsafe_fetch(sp &+ 5) == 0x20_u8
                      add_match(id &+ 43 &* n, l &+ 6, l, matches)
                    end
                  elsif c4 == 0x69_u8 # 'i'
                    if data.unsafe_fetch(sp &+ 5) == 0x73_u8 &&
                       data.unsafe_fetch(sp &+ 6) == 0x20_u8
                      add_match(id &+ 75 &* n, l &+ 7, l, matches)
                    end
                  end
                end
              end
            elsif s0 == 0x2C_u8 # ','
              add_match(id &+ 76 &* n, l &+ 1, l, matches)
              add_match(id &+ 14 &* n, l &+ 2, l, matches) if s1 == 0x20_u8
            elsif s0 == 0x0A_u8 # '\n'
              add_match(id &+ 22 &* n, l &+ 1, l, matches)
              add_match(id &+ 50 &* n, l &+ 2, l, matches) if s1 == 0x09_u8
            elsif s0 == 0x5D_u8 # ']'
              add_match(id &+ 24 &* n, l &+ 1, l, matches)
            elsif s0 == 0x27_u8 # '\''
              add_match(id &+ 36 &* n, l &+ 1, l, matches)
            elsif s0 == 0x3A_u8 # ':'
              add_match(id &+ 51 &* n, l &+ 1, l, matches)
            elsif s0 == 0x28_u8 # '('
              add_match(id &+ 57 &* n, l &+ 1, l, matches)
            elsif s0 == 0x3D_u8 # '='
              if s1 == 0x22_u8
                add_match(id &+ 70 &* n, l &+ 2, l, matches)
              elsif s1 == 0x27_u8
                add_match(id &+ 86 &* n, l &+ 2, l, matches)
              end
            elsif s0 == 0x61_u8 # 'a'
              if s1 == 0x6C_u8 && s2 == 0x20_u8 # "l "
                add_match(id &+ 84 &* n, l &+ 3, l, matches)
              end
            elsif s0 == 0x65_u8 # 'e'
              if s1 == 0x64_u8 # 'd'
                add_match(id &+ 53 &* n, l &+ 3, l, matches) if s2 == 0x20_u8
              elsif s1 == 0x72_u8 # 'r'
                add_match(id &+ 82 &* n, l &+ 3, l, matches) if s2 == 0x20_u8
              elsif s1 == 0x73_u8 # 's'
                if s2 == 0x74_u8 && data.unsafe_fetch(sp &+ 3) == 0x20_u8
                  add_match(id &+ 95 &* n, l &+ 4, l, matches)
                end
              end
            elsif s0 == 0x66_u8 # 'f'
              if s1 == 0x75_u8 && s2 == 0x6C_u8 &&
                 data.unsafe_fetch(sp &+ 3) == 0x20_u8 # "ul "
                add_match(id &+ 90 &* n, l &+ 4, l, matches)
              end
            elsif s0 == 0x69_u8 # 'i'
              if s1 == 0x76_u8 # 'v'
                if s2 == 0x65_u8 && data.unsafe_fetch(sp &+ 3) == 0x20_u8
                  add_match(id &+ 92 &* n, l &+ 4, l, matches)
                end
              elsif s1 == 0x7A_u8 # 'z'
                if s2 == 0x65_u8 && data.unsafe_fetch(sp &+ 3) == 0x20_u8
                  add_match(id &+ 100 &* n, l &+ 4, l, matches)
                end
              end
            elsif s0 == 0x6C_u8 # 'l'
              if s1 == 0x65_u8 # 'e'
                if s2 == 0x73_u8 && data.unsafe_fetch(sp &+ 3) == 0x73_u8 &&
                   data.unsafe_fetch(sp &+ 4) == 0x20_u8
                  add_match(id &+ 93 &* n, l &+ 5, l, matches)
                end
              elsif s1 == 0x79_u8 # 'y'
                add_match(id &+ 61 &* n, l &+ 3, l, matches) if s2 == 0x20_u8
              end
            elsif s0 == 0x6F_u8 # 'o'
              if s1 == 0x75_u8 && s2 == 0x73_u8 &&
                 data.unsafe_fetch(sp &+ 3) == 0x20_u8
                add_match(id &+ 106 &* n, l &+ 4, l, matches)
              end
            end
          else
            # UPPERCASE_FIRST (10) / UPPERCASE_ALL (11) transforms.
            is_all_caps = w_transform != 10
            next unless dict_is_match?(dict, l, w_transform, id, data, pos,
                                       max_length)
            # "" + kUppercase{First,All} + ""
            add_match(id &+ (is_all_caps ? 44 : 9) &* n, l, l, matches)
            has_found_match = true
            next if l &+ 1 >= max_length
            # "" + kUppercase{First,All} + <suffix>
            sp = pos &+ l
            s0 = data.unsafe_fetch(sp)
            s1 = data.unsafe_fetch(sp &+ 1)
            if s0 == 0x20_u8
              add_match(id &+ (is_all_caps ? 68 : 4) &* n, l &+ 1, l, matches)
            elsif s0 == 0x22_u8 # '"'
              add_match(id &+ (is_all_caps ? 87 : 66) &* n, l &+ 1, l, matches)
              if s1 == 0x3E_u8 # '>'
                add_match(id &+ (is_all_caps ? 97 : 69) &* n, l &+ 2, l,
                          matches)
              end
            elsif s0 == 0x2E_u8 # '.'
              add_match(id &+ (is_all_caps ? 101 : 79) &* n, l &+ 1, l,
                        matches)
              if s1 == 0x20_u8
                add_match(id &+ (is_all_caps ? 114 : 88) &* n, l &+ 2, l,
                          matches)
              end
            elsif s0 == 0x2C_u8 # ','
              add_match(id &+ (is_all_caps ? 112 : 99) &* n, l &+ 1, l,
                        matches)
              if s1 == 0x20_u8
                add_match(id &+ (is_all_caps ? 107 : 58) &* n, l &+ 2, l,
                          matches)
              end
            elsif s0 == 0x27_u8 # '\''
              add_match(id &+ (is_all_caps ? 94 : 74) &* n, l &+ 1, l, matches)
            elsif s0 == 0x28_u8 # '('
              add_match(id &+ (is_all_caps ? 113 : 78) &* n, l &+ 1, l, matches)
            elsif s0 == 0x3D_u8 # '='
              if s1 == 0x22_u8
                add_match(id &+ (is_all_caps ? 105 : 104) &* n, l &+ 2, l,
                          matches)
              elsif s1 == 0x27_u8
                add_match(id &+ (is_all_caps ? 116 : 108) &* n, l &+ 2, l,
                          matches)
              end
            end
          end
        end

        # Transforms with prefixes " " and "."
        if max_length >= 5 &&
           (data.unsafe_fetch(pos) == 0x20_u8 || data.unsafe_fetch(pos) == 0x2E_u8)
          is_space = data.unsafe_fetch(pos) == 0x20_u8
          offset = dict.buckets.unsafe_fetch(hash15(data, pos &+ 1)).to_i32
          end_ = offset == 0
          until end_
            w_raw_len = dict.dict_words_len.unsafe_fetch(offset).to_i32
            l = w_raw_len & 0x1F
            n = 1_i32 << dict.size_bits_by_length.unsafe_fetch(l)
            id = dict.dict_words_idx.unsafe_fetch(offset).to_i32
            w_transform = dict.dict_words_transform.unsafe_fetch(offset).to_i32
            offset &+= 1
            end_ = (w_raw_len & 0x80) != 0
            if w_transform == 0
              next unless dict_is_match?(dict, l, w_transform, id, data,
                                         pos &+ 1, max_length &- 1)
              # " " + IDENTITY + "" / "." + IDENTITY + ""
              add_match(id &+ (is_space ? 6 : 32) &* n, l &+ 1, l, matches)
              has_found_match = true
              next if l &+ 2 >= max_length
              # " " + IDENTITY + <suffix> / "." + IDENTITY + <suffix>
              sp = pos &+ l &+ 1
              s0 = data.unsafe_fetch(sp)
              s1 = data.unsafe_fetch(sp &+ 1)
              if s0 == 0x20_u8
                add_match(id &+ (is_space ? 2 : 77) &* n, l &+ 2, l, matches)
              elsif s0 == 0x28_u8 # '('
                add_match(id &+ (is_space ? 89 : 67) &* n, l &+ 2, l, matches)
              elsif is_space
                if s0 == 0x2C_u8 # ','
                  add_match(id &+ 103 &* n, l &+ 2, l, matches)
                  if s1 == 0x20_u8
                    add_match(id &+ 33 &* n, l &+ 3, l, matches)
                  end
                elsif s0 == 0x2E_u8 # '.'
                  add_match(id &+ 71 &* n, l &+ 2, l, matches)
                  if s1 == 0x20_u8
                    add_match(id &+ 52 &* n, l &+ 3, l, matches)
                  end
                elsif s0 == 0x3D_u8 # '='
                  if s1 == 0x22_u8
                    add_match(id &+ 81 &* n, l &+ 3, l, matches)
                  elsif s1 == 0x27_u8
                    add_match(id &+ 98 &* n, l &+ 3, l, matches)
                  end
                end
              end
            elsif is_space
              is_all_caps = w_transform != 10
              next unless dict_is_match?(dict, l, w_transform, id, data,
                                         pos &+ 1, max_length &- 1)
              # " " + kUppercase{First,All} + ""
              add_match(id &+ (is_all_caps ? 85 : 30) &* n, l &+ 1, l, matches)
              has_found_match = true
              next if l &+ 2 >= max_length
              # " " + kUppercase{First,All} + <suffix>
              sp = pos &+ l &+ 1
              s0 = data.unsafe_fetch(sp)
              s1 = data.unsafe_fetch(sp &+ 1)
              if s0 == 0x20_u8
                add_match(id &+ (is_all_caps ? 83 : 15) &* n, l &+ 2, l,
                          matches)
              elsif s0 == 0x2C_u8 # ','
                unless is_all_caps
                  add_match(id &+ 109 &* n, l &+ 2, l, matches)
                end
                if s1 == 0x20_u8
                  add_match(id &+ (is_all_caps ? 111 : 65) &* n, l &+ 3, l,
                            matches)
                end
              elsif s0 == 0x2E_u8 # '.'
                add_match(id &+ (is_all_caps ? 115 : 96) &* n, l &+ 2, l,
                          matches)
                if s1 == 0x20_u8
                  add_match(id &+ (is_all_caps ? 117 : 91) &* n, l &+ 3, l,
                            matches)
                end
              elsif s0 == 0x3D_u8 # '='
                if s1 == 0x22_u8
                  add_match(id &+ (is_all_caps ? 110 : 118) &* n, l &+ 3, l,
                            matches)
                elsif s1 == 0x27_u8
                  add_match(id &+ (is_all_caps ? 119 : 120) &* n, l &+ 3, l,
                            matches)
                end
              end
            end
          end
        end

        # Transforms with prefixes "e ", "s ", ", " and "\xC2\xA0"
        if max_length >= 6
          d0 = data.unsafe_fetch(pos)
          d1 = data.unsafe_fetch(pos &+ 1)
          if (d1 == 0x20_u8 && (d0 == 0x65_u8 || d0 == 0x73_u8 || d0 == 0x2C_u8)) ||
             (d0 == 0xC2_u8 && d1 == 0xA0_u8)
            offset = dict.buckets.unsafe_fetch(hash15(data, pos &+ 2)).to_i32
            end_ = offset == 0
            until end_
              w_raw_len = dict.dict_words_len.unsafe_fetch(offset).to_i32
              l = w_raw_len & 0x1F
              n = 1_i32 << dict.size_bits_by_length.unsafe_fetch(l)
              id = dict.dict_words_idx.unsafe_fetch(offset).to_i32
              w_transform = dict.dict_words_transform.unsafe_fetch(offset).to_i32
              offset &+= 1
              end_ = (w_raw_len & 0x80) != 0
              next unless w_transform == 0 &&
                          dict_is_match?(dict, l, w_transform, id, data,
                                         pos &+ 2, max_length &- 2)
              if d0 == 0xC2_u8
                add_match(id &+ 102 &* n, l &+ 2, l, matches)
                has_found_match = true
              elsif l &+ 2 < max_length &&
                    data.unsafe_fetch(pos &+ l &+ 2) == 0x20_u8
                t = d0 == 0x65_u8 ? 18 : (d0 == 0x73_u8 ? 7 : 13)
                add_match(id &+ t &* n, l &+ 3, l, matches)
                has_found_match = true
              end
            end
          end
        end

        # Transforms with prefixes " the " and ".com/"
        if max_length >= 9
          d0 = data.unsafe_fetch(pos)
          if (d0 == 0x20_u8 && data.unsafe_fetch(pos &+ 1) == 0x74_u8 &&
              data.unsafe_fetch(pos &+ 2) == 0x68_u8 &&
              data.unsafe_fetch(pos &+ 3) == 0x65_u8 &&
              data.unsafe_fetch(pos &+ 4) == 0x20_u8) ||
             (d0 == 0x2E_u8 && data.unsafe_fetch(pos &+ 1) == 0x63_u8 &&
              data.unsafe_fetch(pos &+ 2) == 0x6F_u8 &&
              data.unsafe_fetch(pos &+ 3) == 0x6D_u8 &&
              data.unsafe_fetch(pos &+ 4) == 0x2F_u8)
            offset = dict.buckets.unsafe_fetch(hash15(data, pos &+ 5)).to_i32
            end_ = offset == 0
            until end_
              w_raw_len = dict.dict_words_len.unsafe_fetch(offset).to_i32
              l = w_raw_len & 0x1F
              n = 1_i32 << dict.size_bits_by_length.unsafe_fetch(l)
              id = dict.dict_words_idx.unsafe_fetch(offset).to_i32
              w_transform = dict.dict_words_transform.unsafe_fetch(offset).to_i32
              offset &+= 1
              end_ = (w_raw_len & 0x80) != 0
              next unless w_transform == 0 &&
                          dict_is_match?(dict, l, w_transform, id, data,
                                         pos &+ 5, max_length &- 5)
              add_match(id &+ (d0 == 0x20_u8 ? 41 : 72) &* n, l &+ 5, l,
                        matches)
              has_found_match = true
              next unless l &+ 5 < max_length
              sp = pos &+ l &+ 5
              if d0 == 0x20_u8
                if l &+ 8 < max_length &&
                   data.unsafe_fetch(sp) == 0x20_u8 &&
                   data.unsafe_fetch(sp &+ 1) == 0x6F_u8 &&
                   data.unsafe_fetch(sp &+ 2) == 0x66_u8 &&
                   data.unsafe_fetch(sp &+ 3) == 0x20_u8
                  add_match(id &+ 62 &* n, l &+ 9, l, matches)
                  if l &+ 12 < max_length &&
                     data.unsafe_fetch(sp &+ 4) == 0x74_u8 &&
                     data.unsafe_fetch(sp &+ 5) == 0x68_u8 &&
                     data.unsafe_fetch(sp &+ 6) == 0x65_u8 &&
                     data.unsafe_fetch(sp &+ 7) == 0x20_u8
                    add_match(id &+ 73 &* n, l &+ 13, l, matches)
                  end
                end
              end
            end
          end
        end

        has_found_match
      end
    end
  end
end
