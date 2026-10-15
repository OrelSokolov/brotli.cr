# Port of c/enc/encoder_dict.{c,h} subset: the RFC 7932 static dictionary
# lookup structure for the encoder (single built-in dictionary; compound /
# attached / contextual dictionaries are out of scope). The data tables come
# from the E0 dump (enc_tables_data.cr) and the decoder-side dictionary
# (dictionary_data.cr / tables_data.cr). Upstream: 42a2ed4.

module Brotli
  module Enc
    # static_dict_lut.h:20 — DictWord {len (0x80 = end of bucket), transform,
    # idx}; here as parallel slices from the E0 dump.
    class EncoderDictionary
      getter hash_table_words : Slice(UInt16)   # kStaticDictionaryHashWords
      getter hash_table_lengths : Bytes         # kStaticDictionaryHashLengths
      getter buckets : Slice(UInt16)            # kStaticDictionaryBuckets
      getter dict_words_len : Bytes             # kStaticDictionaryWords[*].len
      getter dict_words_transform : Bytes       # .transform
      getter dict_words_idx : Slice(UInt16)     # .idx
      getter num_transforms : Int32
      getter cutoff_transforms : UInt64
      getter cutoff_transforms_count : Int32

      # Word data (BrotliDictionary): shared with the decoder.
      getter data : Bytes # DICTIONARY_DATA
      getter offsets_by_length : Array(Int32)
      getter size_bits_by_length : Bytes
      getter min_dictionary_word_length : Int32
      getter max_dictionary_word_length : Int32

      def initialize
        @hash_table_words = Enc::DICT_HASH_WORDS
        @hash_table_lengths = Enc::DICT_HASH_LENGTHS
        @buckets = Enc::STATIC_DICTIONARY_BUCKETS
        @dict_words_len = Enc::STATIC_DICTIONARY_WORDS_LEN
        @dict_words_transform = Enc::STATIC_DICTIONARY_WORDS_TRANSFORM
        @dict_words_idx = Enc::STATIC_DICTIONARY_WORDS_IDX
        @num_transforms = Brotli::Transform::NUM_TRANSFORMS
        # hash.h:67 — kCutoffTransforms = MAKE_UINT64_T(0x071B520A, 0xDA2D3200).
        @cutoff_transforms = 0x071B520ADA2D3200_u64
        @cutoff_transforms_count = 10

        @data = Brotli::DICTIONARY_DATA
        @offsets_by_length = Brotli::DICTIONARY_OFFSETS_BY_LENGTH
        @size_bits_by_length = Brotli::DICTIONARY_SIZE_BITS_BY_LENGTH
        @min_dictionary_word_length = 4
        @max_dictionary_word_length = 24
      end

      # Single shared instance (C attaches it to the encoder state).
      def self.default : EncoderDictionary
        @@default ||= new
      end
    end
  end
end
