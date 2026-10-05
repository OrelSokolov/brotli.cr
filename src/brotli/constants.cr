# Port of c/common/constants.h — spec constants. Upstream: 42a2ed4.

module Brotli
  # Specification: 7.3. Encoding of the context map
  CONTEXT_MAP_MAX_RLE = 16

  # Specification: 2. Compressed representation overview
  MAX_NUMBER_OF_BLOCK_TYPES = 256

  # Specification: 3.3. Alphabet sizes
  NUM_LITERAL_SYMBOLS    = 256
  NUM_COMMAND_SYMBOLS    = 704
  NUM_BLOCK_LEN_SYMBOLS  = 26
  MAX_CONTEXT_MAP_SYMBOLS = MAX_NUMBER_OF_BLOCK_TYPES + CONTEXT_MAP_MAX_RLE
  MAX_BLOCK_TYPE_SYMBOLS  = MAX_NUMBER_OF_BLOCK_TYPES + 2

  # Specification: 3.5. Complex prefix codes
  REPEAT_PREVIOUS_CODE_LENGTH = 16
  REPEAT_ZERO_CODE_LENGTH     = 17
  CODE_LENGTH_CODES           = REPEAT_ZERO_CODE_LENGTH + 1 # 18
  INITIAL_REPEATED_CODE_LENGTH = 8

  # "Large Window Brotli"
  LARGE_MAX_DISTANCE_BITS = 62_u32
  LARGE_MIN_WBITS         = 10
  LARGE_MAX_WBITS         = 30

  # Specification: 4. Encoding of distances
  NUM_DISTANCE_SHORT_CODES = 16
  MAX_NPOSTFIX             = 3
  MAX_NDIRECT              = 120
  MAX_DISTANCE_BITS        = 24_u32

  # Specification: 4. Literal/copy lengths
  NUM_INS_COPY_CODES = 24

  # 7.1/7.2 Context bits
  LITERAL_CONTEXT_BITS  = 6
  DISTANCE_CONTEXT_BITS = 2

  # 9.1. Stream header
  WINDOW_GAP = 16

  # ((1 << 26) - 4): maximal RFC 7932 distance (NPOSTFIX=0, NDIRECT=0)
  MAX_DISTANCE = 0x3FFFFFC
  # ((1 << 31) - 4): safe distance limit
  MAX_ALLOWED_DISTANCE = 0x7FFFFFFC

  # Context map RLE / misc used by decode.c
  HUFFMAN_MAX_LENGTH = 18 # BROTLI_HUFFMAN_MAX_LENGTH_258 etc. handled inline

  def self.max_backward_limit(w : Int32) : Int32
    (1 << w) - WINDOW_GAP
  end

  def self.distance_alphabet_size(npostfix : Int32, ndirect : Int32,
                                  max_nbits : Int32) : Int32
    NUM_DISTANCE_SHORT_CODES + ndirect + (max_nbits << (npostfix + 1))
  end

  NUM_DISTANCE_SYMBOLS = distance_alphabet_size(MAX_NPOSTFIX,
                                                MAX_NDIRECT,
                                                LARGE_MAX_DISTANCE_BITS.to_i32) # 1128
end
