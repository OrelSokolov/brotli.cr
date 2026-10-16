# Port of c/enc/params.h, quality.h and BrotliInitDistanceParams
# (metablock.c). Upstream: 42a2ed4.
#
# Deviations from C (accepted, see PLAN.md):
#   * large window (lgwin > 24) is not supported — sanitize_params! clamps
#     lgwin to 22 like C does with large_window = FALSE, so the composite
#     hasher remaps (H35/H55/H65) in ChooseHasher are unreachable and cut;
#   * no SIMD hashers — ChooseHasher always picks scalar H5/H6.

module Brotli
  module Enc
    enum Mode
      Generic = 0
      Text    = 1
      Font    = 2
    end

    MIN_QUALITY = 0
    MAX_QUALITY = 11

    MIN_WINDOW_BITS = 10
    MAX_WINDOW_BITS = 22 # BROTLI_MAX_WINDOW_BITS (no large window)

    MIN_INPUT_BLOCK_BITS = 16
    MAX_INPUT_BLOCK_BITS = 24

    FAST_ONE_PASS_COMPRESSION_QUALITY  = 0
    FAST_TWO_PASS_COMPRESSION_QUALITY  = 1
    ZOPFLIFICATION_QUALITY             = 10
    HQ_ZOPFLIFICATION_QUALITY          = 11

    MAX_QUALITY_FOR_STATIC_ENTROPY_CODES    = 2
    MIN_QUALITY_FOR_BLOCK_SPLIT             = 4
    MIN_QUALITY_FOR_NONZERO_DISTANCE_PARAMS = 4
    MIN_QUALITY_FOR_OPTIMIZE_HISTOGRAMS     = 4
    MIN_QUALITY_FOR_EXTENSIVE_REFERENCE_SEARCH = 5
    MIN_QUALITY_FOR_CONTEXT_MODELING        = 5
    MIN_QUALITY_FOR_HQ_CONTEXT_MODELING     = 7
    MIN_QUALITY_FOR_HQ_BLOCK_SPLITTING      = 10

    # For quality below MIN_QUALITY_FOR_BLOCK_SPLIT there is no block
    # splitting, so we buffer at most this much literals and commands.
    MAX_NUM_DELAYED_SYMBOLS = 0x2FFF

    # The maximum length for which the zopflification uses distinct distances.
    MAX_ZOPFLI_LEN_QUALITY_10 = 150
    MAX_ZOPFLI_LEN_QUALITY_11 = 325

    # Do not thoroughly search when a long copy is found.
    LONG_COPY_QUICK_STEP = 16384

    class HasherParams
      property type : Int32 = 0
      property bucket_bits : Int32 = 0
      property block_bits : Int32 = 0
      property num_last_distances_to_check : Int32 = 0

      def initialize
      end

      def initialize(@type : Int32)
      end
    end

    class DistanceParams
      property distance_postfix_bits : UInt32 = 0
      property num_direct_distance_codes : UInt32 = 0
      property alphabet_size_max : UInt32 = 0
      property alphabet_size_limit : UInt32 = 0
      property max_distance : UInt64 = 0

      def initialize
      end

      # Deep copy (used by BrotliBuildMetaBlock's parameter grid).
      def dup : DistanceParams
        d = DistanceParams.new
        d.copy_from(self)
        d
      end

      def copy_from(other : DistanceParams) : Nil
        @distance_postfix_bits = other.distance_postfix_bits
        @num_direct_distance_codes = other.num_direct_distance_codes
        @alphabet_size_max = other.alphabet_size_max
        @alphabet_size_limit = other.alphabet_size_limit
        @max_distance = other.max_distance
      end
    end

    class Params
      property mode : Mode = Mode::Generic
      property quality : Int32 = MAX_QUALITY
      property lgwin : Int32 = 22
      property lgblock : Int32 = 0
      property size_hint : UInt64 = 0
      property disable_literal_context_modeling : Bool = false
      property large_window : Bool = false # always false (no large window)
      property hasher : HasherParams = HasherParams.new
      property dist : DistanceParams = DistanceParams.new

      def initialize(@quality : Int32 = MAX_QUALITY, @lgwin : Int32 = 22)
      end

      # Deep copy for WriteMetaBlockInternal's block_params (encode.c:530);
      # dist is deep-copied because BuildMetaBlock retunes it in place.
      def dup : Params
        p = Params.new(@quality, @lgwin)
        p.mode = @mode
        p.lgblock = @lgblock
        p.size_hint = @size_hint
        p.disable_literal_context_modeling = @disable_literal_context_modeling
        p.large_window = @large_window
        p.hasher.type = @hasher.type
        p.hasher.bucket_bits = @hasher.bucket_bits
        p.hasher.block_bits = @hasher.block_bits
        p.hasher.num_last_distances_to_check = @hasher.num_last_distances_to_check
        p.dist = @dist.dup
        p
      end
    end

    def self.max_hash_table_size(quality : Int32) : Int32
      quality == FAST_ONE_PASS_COMPRESSION_QUALITY ? 1 << 15 : 1 << 17
    end

    def self.max_zopfli_len(params : Params) : Int32
      params.quality <= 10 ? MAX_ZOPFLI_LEN_QUALITY_10 : MAX_ZOPFLI_LEN_QUALITY_11
    end

    def self.max_zopfli_candidates(params : Params) : Int32
      params.quality <= 10 ? 1 : 5
    end

    def self.sanitize_params!(params : Params) : Nil
      params.quality = Math.min(MAX_QUALITY, Math.max(MIN_QUALITY, params.quality))
      if params.quality <= MAX_QUALITY_FOR_STATIC_ENTROPY_CODES
        params.large_window = false
      end
      if params.lgwin < MIN_WINDOW_BITS
        params.lgwin = MIN_WINDOW_BITS
      else
        max_lgwin = params.large_window ? Brotli::LARGE_MAX_WBITS : MAX_WINDOW_BITS
        params.lgwin = max_lgwin if params.lgwin > max_lgwin
      end
    end

    # Returns optimized lg_block value.
    def self.compute_lg_block(params : Params) : Int32
      lgblock = params.lgblock
      if params.quality == FAST_ONE_PASS_COMPRESSION_QUALITY ||
         params.quality == FAST_TWO_PASS_COMPRESSION_QUALITY
        lgblock = params.lgwin
      elsif params.quality < MIN_QUALITY_FOR_BLOCK_SPLIT
        lgblock = 14
      elsif lgblock == 0
        lgblock = 16
        if params.quality >= 9 && params.lgwin > lgblock
          lgblock = Math.min(18, params.lgwin)
        end
      else
        lgblock = Math.min(MAX_INPUT_BLOCK_BITS,
                           Math.max(MIN_INPUT_BLOCK_BITS, lgblock))
      end
      lgblock
    end

    # Log2 of the main ring buffer area size: allocate lgwin + 1 bits so the
    # new block fits completely, and read_block_size_bits + 1 bits so the
    # copy tail stays smaller than the ring buffer.
    def self.compute_rb_bits(params : Params) : Int32
      1 + Math.max(params.lgwin, params.lgblock)
    end

    def self.max_metablock_size(params : Params) : UInt64
      1_u64 << Math.min(compute_rb_bits(params), MAX_INPUT_BLOCK_BITS)
    end

    # Applied only to qualities 2..9: after this many literals without a
    # match, match lookups get sparse.
    def self.literal_spree_length_for_sparse_search(params : Params) : Int32
      params.quality < 9 ? 64 : 512
    end

    # Quality -> hasher mapping (see quality.h comment table):
    #   q0..q4: H2/H3/H4 (longest_match_quickly), H54 for q4 + 1MB inputs
    #   q5..q9: H40/H41/H42 (forgetful chain) for lgwin <= 16,
    #           H5/H6 (longest match) otherwise
    #   q10+:   H10 (binary tree)
    def self.choose_hasher(params : Params, hparams : HasherParams) : Nil
      if params.quality > 9
        hparams.type = 10
      elsif params.quality == 4 && params.size_hint >= (1 << 20)
        hparams.type = 54
      elsif params.quality < 5
        hparams.type = params.quality
      elsif params.lgwin <= 16
        hparams.type = params.quality < 7 ? 40 : (params.quality < 9 ? 41 : 42)
      elsif params.size_hint >= (1 << 20) && params.lgwin >= 19
        hparams.type = 6
        hparams.block_bits = params.quality - 1
        hparams.bucket_bits = 15
        hparams.num_last_distances_to_check =
          params.quality < 7 ? 4 : (params.quality < 9 ? 10 : 16)
      else
        hparams.type = 5
        hparams.block_bits = params.quality - 1
        hparams.bucket_bits = params.quality < 7 ? 14 : 15
        hparams.num_last_distances_to_check =
          params.quality < 7 ? 4 : (params.quality < 9 ? 10 : 16)
      end
      # C remaps H3->H35, H54->H55, H6->H65 for lgwin > 24 (large window);
      # unreachable here because lgwin <= MAX_WINDOW_BITS.
    end

    # metablock.c: BrotliInitDistanceParams (large_window branch cut).
    def self.init_distance_params(dist : DistanceParams, npostfix : UInt32,
                                  ndirect : UInt32) : Nil
      dist.distance_postfix_bits = npostfix
      dist.num_direct_distance_codes = ndirect

      alphabet_size_max = Brotli.distance_alphabet_size(
        npostfix.to_i32, ndirect.to_i32, Brotli::MAX_DISTANCE_BITS.to_i32).to_u32!
      dist.alphabet_size_max = alphabet_size_max
      dist.alphabet_size_limit = alphabet_size_max
      dist.max_distance = ndirect.to_u64 &+
                          (1_u64 << (Brotli::MAX_DISTANCE_BITS + npostfix + 2)) &-
                          (1_u64 << (npostfix + 2))
    end
  end
end
