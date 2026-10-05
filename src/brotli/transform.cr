# Port of c/common/transform.c — RFC 7932 word transforms.
# Upstream: 42a2ed4. Data lives in tables_data.cr (generated).
# The built-in transforms have params == NULL, so SHIFT_FIRST /
# SHIFT_ALL never occur (upstream would crash on them too); they are
# not ported.

module Brotli
  module Transform
    # enum BrotliWordTransformType
    IDENTITY         =  0
    OMIT_LAST_1      =  1
    OMIT_LAST_9      =  9
    UPPERCASE_FIRST  = 10
    UPPERCASE_ALL    = 11
    OMIT_FIRST_1     = 12
    OMIT_FIRST_9     = 20
    TRANSFORMS_MAX_CUT_OFF = OMIT_LAST_9

    NUM_TRANSFORMS = TRANSFORMS_DATA.size // 3

    def self.prefix_id(idx) : UInt8
      TRANSFORMS_DATA[idx &* 3]
    end

    def self.type(idx) : UInt8
      TRANSFORMS_DATA[idx &* 3 + 1]
    end

    def self.suffix_id(idx) : UInt8
      TRANSFORMS_DATA[idx &* 3 + 2]
    end

    # Pointer to (len, bytes...) string in kPrefixSuffix.
    private def self.prefix_suffix(str_id : Int32) : Int32
      TRANSFORM_PREFIX_SUFFIX_MAP.unsafe_fetch(str_id).to_i32
    end

    private def self.to_upper_case(dst : Bytes, p : Int32) : Int32
      c = dst.unsafe_fetch(p)
      if c < 0xC0
        if c >= 'a'.ord && c <= 'z'.ord
          dst.unsafe_put(p, c ^ 32)
        end
        1
      elsif c < 0xE0
        # An overly simplified uppercasing model for UTF-8.
        dst.unsafe_put(p + 1, dst.unsafe_fetch(p + 1) ^ 32)
        2
      else
        # An arbitrary transform for three byte characters.
        dst.unsafe_put(p + 2, dst.unsafe_fetch(p + 2) ^ 5)
        3
      end
    end

    # BrotliTransformDictionaryWord: writes into dst[dst_pos...], reads
    # word[word_pos, len]. Returns the resulting length.
    def self.dictionary_word(dst : Bytes, dst_pos : Int32, word : Bytes,
                             word_pos : Int32, len : Int32,
                             transform_idx : Int32) : Int32
      idx = 0
      prefix = prefix_suffix(prefix_id(transform_idx))
      suffix = prefix_suffix(suffix_id(transform_idx))
      t = type(transform_idx)

      prefix_len = TRANSFORM_PREFIX_SUFFIX.unsafe_fetch(prefix)
      prefix_len.times do |k|
        dst.unsafe_put(dst_pos + idx, TRANSFORM_PREFIX_SUFFIX.unsafe_fetch(prefix + 1 + k))
        idx += 1
      end

      w = word_pos
      if t <= OMIT_LAST_9
        len -= t
      elsif t >= OMIT_FIRST_1 && t <= OMIT_FIRST_9
        skip = t - (OMIT_FIRST_1 - 1)
        w += skip
        len -= skip
      end

      i = 0
      while i < len
        dst.unsafe_put(dst_pos + idx, word.unsafe_fetch(w + i))
        idx += 1
        i += 1
      end

      if t == UPPERCASE_FIRST
        # Unconditional, like C: dst has 542 bytes of write-ahead slack,
        # and any stray byte is overwritten by the suffix below.
        to_upper_case(dst, dst_pos + idx - len)
      elsif t == UPPERCASE_ALL
        p = dst_pos + idx - len
        remaining = len
        while remaining > 0
          step = to_upper_case(dst, p)
          p += step
          remaining -= step
        end
      end

      suffix_len = TRANSFORM_PREFIX_SUFFIX.unsafe_fetch(suffix)
      suffix_len.times do |k|
        dst.unsafe_put(dst_pos + idx, TRANSFORM_PREFIX_SUFFIX.unsafe_fetch(suffix + 1 + k))
        idx += 1
      end
      idx
    end
  end
end
