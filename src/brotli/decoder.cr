# Port of c/dec/state.{h,c} + c/dec/decode.c — the metablock state machine.
# Upstream: 42a2ed4.
#
# One-shot: Decoder#decode(input) returns the decompressed bytes or raises
# Brotli::DecodeError (code == NEEDS_MORE_INPUT means "truncated input",
# code < 0 are format/alloc errors). The C streaming machinery
# (internal 8-byte buffer, NEEDS_MORE_OUTPUT) is not ported: input is
# copied into a buffer with >= FAST_INPUT_SLACK slack bytes, output goes
# to an unbounded IO::Memory.
#
# Out of scope (paths cut, like the oracle defaults): compound/attached
# dictionaries, large window (the 0x11 marker yields
# FORMAT_WINDOW_BITS), metadata callbacks (metadata bytes are skipped).
#
# NB: BitReader is a Crystal struct; mutating methods MUST be invoked as
# @br.foo (in-place on the ivar slot), never through a local copy or a
# method argument — a copy would drop the mutations.

require "./bit_reader"
require "./huffman"
require "./constants"
require "./types"
require "./tables_data"
require "./cmd_lut_data"
require "./dictionary_data"
require "./transform"

module Brotli
  # BrotliDecoderErrorCode (decode.h). C values kept for oracle parity.
  NO_ERROR                        =  0
  DECODER_SUCCESS                 =  1
  DECODER_NEEDS_MORE_INPUT        =  2
  DECODER_NEEDS_MORE_OUTPUT       =  3
  FORMAT_EXUBERANT_NIBBLE         = -1
  FORMAT_RESERVED                 = -2
  FORMAT_EXUBERANT_META_NIBBLE    = -3
  FORMAT_SIMPLE_HUFFMAN_ALPHABET  = -4
  FORMAT_SIMPLE_HUFFMAN_SAME      = -5
  FORMAT_CL_SPACE                 = -6
  FORMAT_HUFFMAN_SPACE            = -7
  FORMAT_CONTEXT_MAP_REPEAT       = -8
  FORMAT_BLOCK_LENGTH_1           = -9
  FORMAT_BLOCK_LENGTH_2           = -10
  FORMAT_TRANSFORM                = -11
  FORMAT_DICTIONARY               = -12
  FORMAT_WINDOW_BITS              = -13
  FORMAT_PADDING_1                = -14
  FORMAT_PADDING_2                = -15
  FORMAT_DISTANCE                 = -16
  FORMAT_BLOCK_SWITCH             = -17
  COMPOUND_DICTIONARY             = -18
  DICTIONARY_NOT_SET              = -19
  INVALID_ARGUMENTS               = -20
  ALLOC_CONTEXT_MODES             = -21
  ALLOC_TREE_GROUPS               = -22
  ALLOC_CONTEXT_MAP               = -25
  ALLOC_RING_BUFFER_1             = -26
  ALLOC_RING_BUFFER_2             = -27
  ALLOC_BLOCK_TYPE_TREES          = -30
  UNREACHABLE                     = -31

  class DecodeError < Exception
    getter code : Int32

    def initialize(@code : Int32)
      super("brotli decode error code=#{code}")
    end
  end

  # kRingBufferWriteAheadSlack (decode.c:46).
  RING_BUFFER_WRITE_AHEAD_SLACK = 542
  # state.h.
  BLOCK_SIZE_CAP = 1 << 24

  HUFFMAN_TABLE_BITS = 8
  HUFFMAN_TABLE_MASK = 0xFF

  # decode.c:49-62.
  CODE_LENGTH_CODE_ORDER = Bytes[
    1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  ]
  CODE_LENGTH_PREFIX_LENGTH = Bytes[
    2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4,
  ]
  CODE_LENGTH_PREFIX_VALUE = Bytes[
    0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5,
  ]

  # SHARED_BROTLI_*_DICTIONARY_WORD_LENGTH (shared_dictionary.h).
  SHARED_MIN_DICTIONARY_WORD_LENGTH = 4
  SHARED_MAX_DICTIONARY_WORD_LENGTH = 31

  class Decoder
    @br : BitReader
    @output : IO::Memory = IO::Memory.new

    # BrotliDecoderState (state.h); arena.header/arena.body unions are
    # flattened into plain ivars.
    @state : Symbol = :uninitialized
    @substate_metablock_header : Symbol = :none
    @substate_uncompressed : Symbol = :none
    @substate_decode_uint8 : Symbol = :none
    @substate_read_block_length : Symbol = :none
    @substate_huffman : Symbol = :none
    @substate_tree_group : Symbol = :none
    @substate_context_map : Symbol = :none

    @loop_counter : Int32 = 0
    @pos : Int32 = 0
    @rb_roundtrips : Int64 = 0
    @partial_pos_out : Int64 = 0
    @error_code : Int32 = NO_ERROR
    @meta_block_remaining_len : Int32 = 0
    @is_last_metablock : Bool = false
    @is_uncompressed : Bool = false
    @is_metadata : Bool = false
    @should_wrap_ringbuffer : Bool = false
    @window_bits : Int32 = 0
    @max_backward_distance : Int32 = 0
    @max_distance : Int32 = 0
    @ringbuffer : Bytes? = nil
    @ringbuffer_size : Int32 = 0
    @new_ringbuffer_size : Int32 = 0
    @ringbuffer_mask : Int32 = 0
    @dist_rb : StaticArray(Int32, 4) = StaticArray(Int32, 4).new(0)
    @dist_rb_idx : Int32 = 0
    @block_type_trees : Slice(HuffmanCode)
    @block_len_trees : Slice(HuffmanCode)
    @block_length : Slice(Int32)
    @block_length_index : Int32 = 0
    @num_block_types : Slice(Int32)
    @block_type_rb : Slice(Int32)
    @context_map : Bytes? = nil
    @context_modes : Bytes? = nil
    @dist_context_map : Bytes? = nil
    @context_map_slice : Bytes? = nil
    @dist_context_map_slice : Bytes? = nil
    @literal_hgroup : HuffmanTreeGroup = HuffmanTreeGroup.new
    @insert_copy_hgroup : HuffmanTreeGroup = HuffmanTreeGroup.new
    @distance_hgroup : HuffmanTreeGroup = HuffmanTreeGroup.new
    @htree_command : Slice(HuffmanCode)? = nil
    @literal_htree : Slice(HuffmanCode)? = nil
    @trivial_literal_context : Bool = false
    @trivial_literal_contexts : Slice(UInt32)
    @context_lookup_offset : Int32 = 0
    @distance_context : Int32 = 0
    @distance_code : Int32 = 0
    @copy_length : Int32 = 0
    @dist_htree_index : Int32 = 0
    @distance_postfix_bits : Int32 = 0
    @num_direct_distance_codes : Int32 = 0
    @num_literal_htrees : Int32 = 0
    @num_dist_htrees : Int32 = 0
    @size_nibbles : Int32 = 0
    @varlen_uint8_value : Int32 = 0
    @mtf : Bytes = Bytes.new(257)
    @mtf_upper_bound : Int32 = 63

    # MetablockHeaderArena.
    @sub_loop_counter : Int32 = 0
    @repeat_code_len : Int32 = 0
    @prev_code_len : Int32 = 0
    @symbol : Int32 = 0
    @repeat : Int32 = 0
    @space : UInt32 = 0
    @table : Slice(HuffmanCode)
    @symbols_lists_array : Slice(UInt16)
    @next_symbol : Slice(Int32)
    @code_length_code_lengths : Bytes
    @code_length_histo : Slice(UInt16)
    @htree_index : Int32 = 0
    @next_offset : Int32 = 0
    @context_index : Int32 = 0
    @max_run_length_prefix : Int32 = 0
    @code : Int32 = 0
    @context_map_table : Slice(HuffmanCode)

    # MetablockBodyArena.
    @dist_extra_bits : Bytes
    @dist_offset : Slice(Int32)

    def initialize
      @br = BitReader.new(Bytes.new(BitReader::FAST_INPUT_SLACK))
      @block_type_trees = Slice(HuffmanCode).new(
        3 * (HUFFMAN_MAX_SIZE_258 + HUFFMAN_MAX_SIZE_26)) do
        HuffmanCode.new(0_u8, 0_u16)
      end
      @block_len_trees = @block_type_trees + 3 * HUFFMAN_MAX_SIZE_258
      @block_length = Slice(Int32).new(3)
      @num_block_types = Slice(Int32).new(3)
      @block_type_rb = Slice(Int32).new(6)
      @trivial_literal_contexts = Slice(UInt32).new(8)
      @dist_rb[0] = 16
      @dist_rb[1] = 15
      @dist_rb[2] = 11
      @dist_rb[3] = 4
      @table = Slice(HuffmanCode).new(HUFFMAN_MAX_SIZE_272) { HuffmanCode.new(0_u8, 0_u16) }
      @symbols_lists_array = Slice(UInt16).new(720)
      @next_symbol = Slice(Int32).new(32)
      @code_length_code_lengths = Bytes.new(CODE_LENGTH_CODES)
      @code_length_histo = Slice(UInt16).new(16)
      @context_map_table = Slice(HuffmanCode).new(HUFFMAN_MAX_SIZE_272) { HuffmanCode.new(0_u8, 0_u16) }
      @dist_extra_bits = Bytes.new(544)
      @dist_offset = Slice(Int32).new(544)
    end

    def error_code : Int32
      @error_code
    end

    # One-shot decode. Raises DecodeError (code 2 = truncated input).
    def decode(input : Bytes) : Bytes
      # >= FAST_INPUT_SLACK readable bytes past the logical end (the
      # bit_reader.cr contract); 64 also covers the 16-byte copies.
      buf = Bytes.new(input.size + 64)
      input.copy_to(buf)
      @br = BitReader.new(buf, 0, input.size.to_i32)
      @br.init
      result = decode_stream
      if result == DECODER_SUCCESS
        @output.to_slice
      else
        raise DecodeError.new(result)
      end
    end

    # BrotliDecoderDecompressStream (decode.c:2447), one-shot: the
    # internal-buffer refill branch is cut; NEEDS_MORE_INPUT breaks out.
    private def decode_stream : Int32
      result = DECODER_SUCCESS
      loop do
        if result != DECODER_SUCCESS
          if result == DECODER_NEEDS_MORE_INPUT
            # Pro-actively push output (surfaces BLOCK_LENGTH_1).
            if @ringbuffer
              intermediate = write_ring_buffer(true)
              if intermediate < 0
                result = intermediate
                break
              end
            end
          end
          break
        end
        case @state
        when :uninitialized
          unless @br.warmup?
            result = DECODER_NEEDS_MORE_INPUT
            next
          end
          result = decode_window_bits # Reads 1..7 bits.
          next if result != DECODER_SUCCESS
          @state = :initialize
        when :initialize
          # Maximum distance, see section 9.1. of the spec.
          @max_backward_distance = (1 << @window_bits) - WINDOW_GAP
          @state = :metablock_begin
        when :metablock_begin
          metablock_begin
          @state = :metablock_header
        when :metablock_header
          result = decode_meta_block_length # Reads 2 - 31 bits.
          next if result != DECODER_SUCCESS
          if @is_metadata || @is_uncompressed
            unless @br.jump_to_byte_boundary
              result = FORMAT_PADDING_1
              next
            end
          end
          if @is_metadata
            @state = :metadata
            next
          end
          if @meta_block_remaining_len == 0
            @state = :metablock_done
            next
          end
          calculate_ring_buffer_size
          if @is_uncompressed
            @state = :uncompressed
            next
          end
          @state = :before_compressed_metablock_header
        when :before_compressed_metablock_header
          @loop_counter = 0
          # Initialize compressed metablock header arena.
          @sub_loop_counter = 0
          @substate_huffman = :none
          @substate_tree_group = :none
          @substate_context_map = :none
          @state = :huffman_code_0
        when :huffman_code_0
          if @loop_counter >= 3
            @state = :metablock_header_2
            next
          end
          result = decode_var_len_uint8 # Reads 1..11 bits.
          next if result != DECODER_SUCCESS
          @num_block_types[@loop_counter] = @varlen_uint8_value + 1
          if @num_block_types[@loop_counter] < 2
            @loop_counter += 1
            next
          end
          @state = :huffman_code_1
        when :huffman_code_1
          alphabet_size = @num_block_types[@loop_counter] + 2
          code, _ = read_huffman_code(alphabet_size, alphabet_size,
            @block_type_trees + @loop_counter * HUFFMAN_MAX_SIZE_258)
          if code != DECODER_SUCCESS
            result = code
            next
          end
          @state = :huffman_code_2
        when :huffman_code_2
          code, _ = read_huffman_code(NUM_BLOCK_LEN_SYMBOLS, NUM_BLOCK_LEN_SYMBOLS,
            @block_len_trees + @loop_counter * HUFFMAN_MAX_SIZE_26)
          if code != DECODER_SUCCESS
            result = code
            next
          end
          @state = :huffman_code_3
        when :huffman_code_3
          bl = safe_read_block_length(
            @block_len_trees + @loop_counter * HUFFMAN_MAX_SIZE_26)
          if !bl
            result = DECODER_NEEDS_MORE_INPUT
            next
          end
          @block_length[@loop_counter] = bl
          @loop_counter += 1
          @state = :huffman_code_0
        when :uncompressed
          result = copy_uncompressed_block_to_output
          next if result != DECODER_SUCCESS
          @state = :metablock_done
        when :metadata
          result = skip_metadata_block
          next if result != DECODER_SUCCESS
          @state = :metablock_done
        when :metablock_header_2
          bits = @br.safe_read_bits(6)
          if !bits
            result = DECODER_NEEDS_MORE_INPUT
            next
          end
          @distance_postfix_bits = (bits & BitReader.bit_mask(2)).to_i32
          @num_direct_distance_codes =
            ((bits >> 2) << @distance_postfix_bits).to_i32
          @context_modes = Bytes.new(@num_block_types[0])
          @loop_counter = 0
          @state = :context_modes
        when :context_modes
          result = read_context_modes
          next if result != DECODER_SUCCESS
          @state = :context_map_1
        when :context_map_1
          result = decode_context_map(
            @num_block_types[0] << LITERAL_CONTEXT_BITS, literal: true)
          next if result != DECODER_SUCCESS
          detect_trivial_literal_block_types
          @state = :context_map_2
        when :context_map_2
          dasm = Brotli.distance_alphabet_size(@distance_postfix_bits,
            @num_direct_distance_codes, MAX_DISTANCE_BITS.to_i32)
          result = decode_context_map(
            @num_block_types[2] << DISTANCE_CONTEXT_BITS, literal: false)
          next if result != DECODER_SUCCESS
          huffman_tree_group_init(@literal_hgroup, NUM_LITERAL_SYMBOLS,
            NUM_LITERAL_SYMBOLS, @num_literal_htrees)
          huffman_tree_group_init(@insert_copy_hgroup, NUM_COMMAND_SYMBOLS,
            NUM_COMMAND_SYMBOLS, @num_block_types[1])
          huffman_tree_group_init(@distance_hgroup, dasm, dasm, @num_dist_htrees)
          @loop_counter = 0
          @state = :tree_group
        when :tree_group
          hgroup = case @loop_counter
            when 0 then @literal_hgroup
            when 1 then @insert_copy_hgroup
            when 2 then @distance_hgroup
            else        return finish(UNREACHABLE)
          end
          result = huffman_tree_group_decode(hgroup)
          next if result != DECODER_SUCCESS
          @loop_counter += 1
          if @loop_counter < 3
            next
          end
          @state = :before_compressed_metablock_body
        when :before_compressed_metablock_body
          prepare_literal_decoding
          @dist_context_map_slice = @dist_context_map.not_nil!
          @htree_command = @insert_copy_hgroup.htrees[0]
          ensure_ring_buffer
          calculate_distance_lut
          @state = :command_begin
        when :command_begin, :command_inner, :command_post_decode_literals,
             :command_post_wrap_copy
          result = process_commands
          if result == DECODER_NEEDS_MORE_INPUT
            result = safe_process_commands
          end
        when :command_inner_write, :command_post_write_1, :command_post_write_2
          result = write_ring_buffer(false)
          next if result != DECODER_SUCCESS
          wrap_ring_buffer
          if @ringbuffer_size == (1 << @window_bits)
            @max_distance = @max_backward_distance
          end
          case @state
          when :command_post_write_1
            # Compound dictionary copy is cut (never attached).
            if @meta_block_remaining_len == 0
              @state = :metablock_done
            else
              @state = :command_begin
            end
          when :command_post_write_2
            @state = :command_post_wrap_copy
          else # :command_inner_write
            if @loop_counter == 0
              if @meta_block_remaining_len == 0
                @state = :metablock_done
              else
                @state = :command_post_decode_literals
              end
            else
              @state = :command_inner
            end
          end
        when :metablock_done
          if @meta_block_remaining_len < 0
            result = FORMAT_BLOCK_LENGTH_2
            next
          end
          cleanup_after_metablock
          unless @is_last_metablock
            @state = :metablock_begin
            next
          end
          unless @br.jump_to_byte_boundary
            result = FORMAT_PADDING_2
            next
          end
          @state = :done
        when :done
          if @ringbuffer
            result = write_ring_buffer(true)
            next if result != DECODER_SUCCESS
          end
          return finish(DECODER_SUCCESS)
        else
          return finish(UNREACHABLE)
        end
      end
      finish(result)
    end

    private def finish(result : Int32) : Int32
      @error_code = result
      result
    end

    # ------------------------------------------------------------------
    # Small header readers

    # DecodeWindowBits (decode.c:146); large_window is always false, so
    # the 0x11 marker is FORMAT_WINDOW_BITS (like C without the flag).
    private def decode_window_bits : Int32
      n = @br.take_bits(1)
      if n == 0
        @window_bits = 16
        return DECODER_SUCCESS
      end
      n = @br.take_bits(3)
      if n != 0
        @window_bits = ((17 + n) & 63).to_i32
        return DECODER_SUCCESS
      end
      n = @br.take_bits(3)
      if n == 1
        return FORMAT_WINDOW_BITS
      end
      if n != 0
        @window_bits = ((8 + n) & 63).to_i32
        return DECODER_SUCCESS
      end
      @window_bits = 17
      DECODER_SUCCESS
    end

    # DecodeVarLenUint8 (decode.c:193). Result value in @varlen_uint8_value
    # (C persists it through the destination field — same semantics).
    private def decode_var_len_uint8 : Int32
      loop do
        case @substate_decode_uint8
        when :none
          bits = @br.safe_read_bits(1)
          return DECODER_NEEDS_MORE_INPUT unless bits
          if bits == 0
            @varlen_uint8_value = 0
            return DECODER_SUCCESS
          end
          @substate_decode_uint8 = :short
        when :short
          bits = @br.safe_read_bits(3)
          if !bits
            @substate_decode_uint8 = :short
            return DECODER_NEEDS_MORE_INPUT
          end
          if bits == 0
            @varlen_uint8_value = 1
            @substate_decode_uint8 = :none
            return DECODER_SUCCESS
          end
          # Use output value as a temporary storage. It MUST be persisted.
          @varlen_uint8_value = bits.to_i32
          @substate_decode_uint8 = :long
        when :long
          bits = @br.safe_read_bits(@varlen_uint8_value)
          if !bits
            @substate_decode_uint8 = :long
            return DECODER_NEEDS_MORE_INPUT
          end
          @varlen_uint8_value = (1 << @varlen_uint8_value) + bits
          @substate_decode_uint8 = :none
          return DECODER_SUCCESS
        end
      end
    end

    # DecodeMetaBlockLength (decode.c:237).
    private def decode_meta_block_length : Int32
      loop do
        case @substate_metablock_header
        when :none
          bits = @br.safe_read_bits(1)
          return DECODER_NEEDS_MORE_INPUT unless bits
          @is_last_metablock = bits != 0
          @meta_block_remaining_len = 0
          @is_uncompressed = false
          @is_metadata = false
          @substate_metablock_header =
            @is_last_metablock ? :empty : :nibbles
        when :empty
          bits = @br.safe_read_bits(1)
          return DECODER_NEEDS_MORE_INPUT unless bits
          if bits != 0
            @substate_metablock_header = :none
            return DECODER_SUCCESS
          end
          @substate_metablock_header = :nibbles
        when :nibbles
          bits = @br.safe_read_bits(2)
          return DECODER_NEEDS_MORE_INPUT unless bits
          @size_nibbles = (bits + 4).to_i32
          @loop_counter = 0
          if bits == 3
            @is_metadata = true
            @substate_metablock_header = :reserved
            next
          end
          @substate_metablock_header = :size
        when :size
          i = @loop_counter
          while i < @size_nibbles
            bits = @br.safe_read_bits(4)
            if !bits
              @loop_counter = i
              return DECODER_NEEDS_MORE_INPUT
            end
            if i + 1 == @size_nibbles && @size_nibbles > 4 && bits == 0
              return FORMAT_EXUBERANT_NIBBLE
            end
            @meta_block_remaining_len |= (bits << (i * 4)).to_i32
            i += 1
          end
          @substate_metablock_header = :uncompressed
        when :uncompressed
          unless @is_last_metablock
            bits = @br.safe_read_bits(1)
            return DECODER_NEEDS_MORE_INPUT unless bits
            @is_uncompressed = bits != 0
          end
          @meta_block_remaining_len += 1
          @substate_metablock_header = :none
          return DECODER_SUCCESS
        when :reserved
          bits = @br.safe_read_bits(1)
          return DECODER_NEEDS_MORE_INPUT unless bits
          return FORMAT_RESERVED if bits != 0
          @substate_metablock_header = :bytes
        when :bytes
          bits = @br.safe_read_bits(2)
          return DECODER_NEEDS_MORE_INPUT unless bits
          if bits == 0
            @substate_metablock_header = :none
            return DECODER_SUCCESS
          end
          @size_nibbles = bits.to_i32
          @substate_metablock_header = :metadata
        when :metadata
          i = @loop_counter
          while i < @size_nibbles
            bits = @br.safe_read_bits(8)
            if !bits
              @loop_counter = i
              return DECODER_NEEDS_MORE_INPUT
            end
            if i + 1 == @size_nibbles && @size_nibbles > 1 && bits == 0
              return FORMAT_EXUBERANT_META_NIBBLE
            end
            @meta_block_remaining_len |= (bits << (i * 8)).to_i32
            i += 1
          end
          @meta_block_remaining_len += 1
          @substate_metablock_header = :none
          return DECODER_SUCCESS
        end
      end
    end

    # ------------------------------------------------------------------
    # Huffman symbol reading (decode.c:362-519).

    @[AlwaysInline]
    private def decode_symbol(bits : UInt64, table : Slice(HuffmanCode)) : UInt16
      i0 = (bits & HUFFMAN_TABLE_MASK).to_i32!
      e = table.unsafe_fetch(i0)
      if e.bits > HUFFMAN_TABLE_BITS
        nbits = e.bits - HUFFMAN_TABLE_BITS
        @br.drop_bits(HUFFMAN_TABLE_BITS)
        i2 = i0 + e.value +
             ((bits >> HUFFMAN_TABLE_BITS) & BitReader.bit_mask(nbits)).to_i32!
        e = table.unsafe_fetch(i2)
      end
      @br.drop_bits(e.bits)
      e.value
    end

    @[AlwaysInline]
    private def read_symbol(table : Slice(HuffmanCode)) : UInt16
      decode_symbol(@br.get16_bits_unmasked, table)
    end

    # SafeDecodeSymbol (decode.c:387): nil if there is not enough input.
    private def safe_decode_symbol(table : Slice(HuffmanCode)) : UInt16?
      available_bits = @br.available_bits
      if available_bits == 0
        e = table.unsafe_fetch(0)
        if e.bits == 0
          return e.value
        end
        return nil # No valid bits at all.
      end
      val = @br.get_bits_unmasked
      i0 = (val & HUFFMAN_TABLE_MASK).to_i32!
      e = table.unsafe_fetch(i0)
      if e.bits <= HUFFMAN_TABLE_BITS
        if e.bits <= available_bits
          @br.drop_bits(e.bits)
          return e.value
        else
          return nil # Not enough bits for the first level.
        end
      end
      return nil if available_bits <= HUFFMAN_TABLE_BITS

      # Speculatively drop HUFFMAN_TABLE_BITS.
      val = (val & BitReader.bit_mask(e.bits)) >> HUFFMAN_TABLE_BITS
      available_bits -= HUFFMAN_TABLE_BITS
      e2 = table.unsafe_fetch(i0 + e.value + val.to_i32!)
      if available_bits < e2.bits
        return nil # Not enough bits for the second level.
      end
      @br.drop_bits(HUFFMAN_TABLE_BITS + e2.bits)
      e2.value
    end

    private def safe_read_symbol(table : Slice(HuffmanCode)) : UInt16?
      val = @br.safe_get_bits(15)
      if val
        decode_symbol(val, table)
      else
        safe_decode_symbol(table)
      end
    end

    # PreloadSymbol (decode.c:438); only used on the fast path.
    private def preload_symbol(table : Slice(HuffmanCode)) : {UInt8, UInt16}
      val = @br.get_bits(HUFFMAN_TABLE_BITS)
      e = table.unsafe_fetch((val & HUFFMAN_TABLE_MASK).to_i32!)
      {e.bits, e.value}
    end

    # ReadPreloadedSymbol (decode.c:454). Returns the symbol plus the
    # preloaded {bits, value} for the next call.
    private def read_preloaded_symbol(table : Slice(HuffmanCode), pb : UInt8,
                                      pv : UInt16) : {UInt16, UInt8, UInt16}
      result = pv
      if pb > HUFFMAN_TABLE_BITS
        val = @br.get16_bits_unmasked
        idx = ((val & HUFFMAN_TABLE_MASK) + pv).to_i32!
        ext = table.unsafe_fetch(idx)
        mask = BitReader.bit_mask(pb - HUFFMAN_TABLE_BITS)
        @br.drop_bits(HUFFMAN_TABLE_BITS)
        e2 = table.unsafe_fetch(idx + ((val >> HUFFMAN_TABLE_BITS) & mask).to_i32!)
        @br.drop_bits(e2.bits)
        result = e2.value
      else
        @br.drop_bits(pb)
      end
      # PreloadSymbol for the next round.
      v = @br.get_bits(HUFFMAN_TABLE_BITS)
      e = table.unsafe_fetch((v & HUFFMAN_TABLE_MASK).to_i32!)
      {result, e.bits, e.value}
    end

    # BrotliCopyPreloadedSymbolsToU8 (decode.c:478). Returns copies made
    # plus the updated preload values.
    private def copy_preloaded_symbols_to_u8(table : Slice(HuffmanCode),
                                             pb : UInt8, pv : UInt16,
                                             ringbuffer : Bytes, pos : Int32,
                                             limit : Int32) : {Int32, UInt8, UInt16}
      maximal_overread = 4
      # Bytes readable while CheckInputAmount holds, in 15-bit symbols.
      new_lim = (@br.guard_in - @br.next_in).to_i64 &* 8 // 15
      pos_limit = limit
      if new_lim - maximal_overread <= limit
        pos_limit = (new_lim - maximal_overread).to_i32
      end
      pos_limit = 0 if pos_limit < 0
      copies = pos_limit
      pos_limit += pos
      # Fast path: safe to read (verified) and write (caller guaranteed).
      while pos < pos_limit
        sym, pb, pv = read_preloaded_symbol(table, pb, pv)
        ringbuffer.unsafe_put(pos, sym.to_u8!)
        pos += 1
      end
      # Remainder: verify that it is safe to read.
      while @br.check_input_amount && copies < limit
        sym, pb, pv = read_preloaded_symbol(table, pb, pv)
        ringbuffer.unsafe_put(pos, sym.to_u8!)
        pos += 1
        copies += 1
      end
      {copies, pb, pv}
    end

    # Log2Floor (decode.c:522) — actually bit length; x must be > 0.
    private def log2_floor(x : Int32) : Int32
      result = 0
      while x != 0
        x >>= 1
        result += 1
      end
      result
    end


    # ------------------------------------------------------------------
    # Huffman code reading (decode.c:534-930).
    # symbol_lists convention (see huffman.cr): the flat array holds
    # heads for code lengths 1..15 at [len] and chained symbols at
    # [16 + symbol]; @next_symbol[len] keeps the biased write position.

    # ReadSimpleHuffmanSymbols (decode.c:534).
    private def read_simple_huffman_symbols(alphabet_size_max : Int32,
                                            alphabet_size_limit : Int32) : Int32
      # max_bits == 1..11; symbol == 0..3; 1..44 bits will be read.
      max_bits = log2_floor(alphabet_size_max - 1)
      i = @sub_loop_counter
      num_symbols = @symbol
      while i <= num_symbols
        v = @br.safe_read_bits(max_bits)
        if !v
          @sub_loop_counter = i
          @substate_huffman = :simple_read
          return DECODER_NEEDS_MORE_INPUT
        end
        if v >= alphabet_size_limit
          return FORMAT_SIMPLE_HUFFMAN_ALPHABET
        end
        @symbols_lists_array[i] = v.to_u16!
        i += 1
      end

      i = 0
      while i < num_symbols
        k = i + 1
        while k <= num_symbols
          if @symbols_lists_array[i] == @symbols_lists_array[k]
            return FORMAT_SIMPLE_HUFFMAN_SAME
          end
          k += 1
        end
        i += 1
      end

      DECODER_SUCCESS
    end

    # ProcessSingleCodeLength (decode.c:577).
    private def process_single_code_length(code_len : Int32) : Nil
      @repeat = 0
      if code_len != 0 # code_len == 1..15
        @symbols_lists_array[@next_symbol[code_len]] = @symbol.to_u16!
        @next_symbol[code_len] = @symbol + SYMBOL_LISTS_BASE
        @prev_code_len = code_len
        @space &-= (32768 >> code_len).to_u32!
        @code_length_histo[code_len] &+= 1
      end
      @symbol += 1
    end

    # ProcessRepeatedCodeLength (decode.c:604).
    private def process_repeated_code_length(code_len : Int32,
                                             repeat_delta : Int32,
                                             alphabet_size : Int32) : Nil
      extra_bits = 3 # for REPEAT_ZERO_CODE_LENGTH
      new_len = 0 # for REPEAT_ZERO_CODE_LENGTH
      if code_len == REPEAT_PREVIOUS_CODE_LENGTH
        new_len = @prev_code_len
        extra_bits = 2
      end
      if @repeat_code_len != new_len
        @repeat = 0
        @repeat_code_len = new_len
      end
      old_repeat = @repeat
      if @repeat > 0
        @repeat -= 2
        @repeat <<= extra_bits
      end
      @repeat += repeat_delta + 3
      repeat_delta = @repeat - old_repeat
      if @symbol + repeat_delta > alphabet_size
        @symbol = alphabet_size
        @space = 0xFFFFF
        return
      end
      if @repeat_code_len != 0
        last = @symbol + repeat_delta
        next_pos = @next_symbol[@repeat_code_len]
        while true
          @symbols_lists_array[next_pos] = @symbol.to_u16!
          next_pos = @symbol + SYMBOL_LISTS_BASE
          @symbol += 1
          break if @symbol == last
        end
        @next_symbol[@repeat_code_len] = next_pos
        @space &-= (repeat_delta << (15 - @repeat_code_len)).to_u32!
        @code_length_histo[@repeat_code_len] = 
          (@code_length_histo[@repeat_code_len] &+ repeat_delta).to_u16!
      else
        @symbol += repeat_delta
      end
    end

    # ReadSymbolCodeLengths (decode.c:652) — fast path.
    private def read_symbol_code_lengths(alphabet_size : Int32) : Int32
      return DECODER_NEEDS_MORE_INPUT unless @br.warmup?
      while @symbol < alphabet_size && @space > 0
        unless @br.check_input_amount
          return DECODER_NEEDS_MORE_INPUT
        end
        @br.fill_bit_window16
        p0 = @table.unsafe_fetch((@br.get_bits_unmasked & 0x1F).to_i32!)
        @br.drop_bits(p0.bits) # Use 1..5 bits.
        code_len = p0.value # code_len == 0..17
        if code_len < REPEAT_PREVIOUS_CODE_LENGTH
          process_single_code_length(code_len)
        else # code_len == 16..17, extra_bits == 2..3
          extra_bits = code_len == REPEAT_PREVIOUS_CODE_LENGTH ? 2 : 3
          repeat_delta = @br.get_bits_unmasked & BitReader.bit_mask(extra_bits)
          @br.drop_bits(extra_bits)
          process_repeated_code_length(code_len, repeat_delta.to_i32,
            alphabet_size)
        end
      end
      DECODER_SUCCESS
    end

    # SafeReadSymbolCodeLengths (decode.c:702).
    private def safe_read_symbol_code_lengths(alphabet_size : Int32) : Int32
      get_byte = false
      while @symbol < alphabet_size && @space > 0
        return DECODER_NEEDS_MORE_INPUT if get_byte && !@br.pull_byte
        get_byte = false
        available_bits = @br.available_bits
        bits = 0_u64
        bits = @br.get_bits_unmasked if available_bits != 0
        p0 = @table.unsafe_fetch((bits & 0x1F).to_i32!)
        if p0.bits > available_bits
          get_byte = true
          next
        end
        code_len = p0.value # code_len == 0..17
        if code_len < REPEAT_PREVIOUS_CODE_LENGTH
          @br.drop_bits(p0.bits)
          process_single_code_length(code_len)
        else # code_len == 16..17, extra_bits == 2..3
          extra_bits = code_len - 14
          repeat_delta = (bits >> p0.bits) & BitReader.bit_mask(extra_bits)
          if available_bits < p0.bits + extra_bits
            get_byte = true
            next
          end
          @br.drop_bits(p0.bits + extra_bits)
          process_repeated_code_length(code_len, repeat_delta.to_i32,
            alphabet_size)
        end
      end
      DECODER_SUCCESS
    end

    # ReadCodeLengthCodeLengths (decode.c:751).
    private def read_code_length_code_lengths : Int32
      num_codes = @repeat
      space = @space
      i = @sub_loop_counter
      while i < CODE_LENGTH_CODES
        ix = @br.safe_get_bits(4)
        if !ix
          available_bits = @br.available_bits
          ix = available_bits != 0 ? @br.get_bits_unmasked & 0xF : 0_u64
          if CODE_LENGTH_PREFIX_LENGTH.unsafe_fetch(ix.to_i32!) > available_bits
            @sub_loop_counter = i
            @repeat = num_codes
            @space = space
            @substate_huffman = :complex
            return DECODER_NEEDS_MORE_INPUT
          end
        end
        ixi = ix.to_i32!
        v = CODE_LENGTH_PREFIX_VALUE.unsafe_fetch(ixi)
        @br.drop_bits(CODE_LENGTH_PREFIX_LENGTH.unsafe_fetch(ixi))
        @code_length_code_lengths[CODE_LENGTH_CODE_ORDER.unsafe_fetch(i)] = v
        if v != 0
          space = space &- (32 >> v).to_u32!
          num_codes += 1
          @code_length_histo[v] &+= 1
          if space &- 1_u32 >= 32_u32
            # space is 0 or wrapped around.
            break
          end
        end
        i += 1
      end
      unless num_codes == 1 || space == 0
        return FORMAT_CL_SPACE
      end
      DECODER_SUCCESS
    end

    # ReadHuffmanCode (decode.c:807). Writes into `table` (a sub-slice at
    # the desired offset); returns {error code, table size}.
    private def read_huffman_code(alphabet_size_max : Int32,
                                  alphabet_size_limit : Int32,
                                  table : Slice(HuffmanCode)) : {Int32, UInt32}
      loop do
        case @substate_huffman
        when :none
          bits = @br.safe_read_bits(2)
          return {DECODER_NEEDS_MORE_INPUT, 0_u32} unless bits
          # 1 for simple code; 0 no skipping; 2/3 skip code lengths.
          @sub_loop_counter = bits.to_i32
          if @sub_loop_counter != 1
            @space = 32
            @repeat = 0 # num_codes
            6.times { |k| @code_length_histo[k] = 0 }
            @code_length_code_lengths.fill(0)
            @substate_huffman = :complex
            next
          end
          @substate_huffman = :simple_size
        when :simple_size
          # Read symbols, codes & code lengths directly.
          bits = @br.safe_read_bits(2) # num_symbols
          if !bits
            @substate_huffman = :simple_size
            return {DECODER_NEEDS_MORE_INPUT, 0_u32}
          end
          @symbol = bits.to_i32
          @sub_loop_counter = 0
          @substate_huffman = :simple_read
        when :simple_read
          result = read_simple_huffman_symbols(alphabet_size_max,
            alphabet_size_limit)
          if result != DECODER_SUCCESS
            return {result, 0_u32}
          end
          @substate_huffman = :simple_build
        when :simple_build
          if @symbol == 3
            bits = @br.safe_read_bits(1) # tree_select
            if !bits
              @substate_huffman = :simple_build
              return {DECODER_NEEDS_MORE_INPUT, 0_u32}
            end
            @symbol += bits
          end
          table_size = Huffman.build_simple_huffman_table(table,
            HUFFMAN_TABLE_BITS, @symbols_lists_array, @symbol.to_u32)
          @substate_huffman = :none
          return {DECODER_SUCCESS, table_size}
        when :complex
          result = read_code_length_code_lengths
          if result != DECODER_SUCCESS
            return {result, 0_u32}
          end
          Huffman.build_code_lengths_huffman_table(@table,
            @code_length_code_lengths, @code_length_histo)
          @code_length_histo.fill(0)
          (0..HUFFMAN_MAX_CODE_LENGTH).each do |k|
            @next_symbol[k] = k
            @symbols_lists_array[k] = 0xFFFF
          end

          @symbol = 0
          @prev_code_len = INITIAL_REPEATED_CODE_LENGTH
          @repeat = 0
          @repeat_code_len = 0
          @space = 32768
          @substate_huffman = :length_symbols
        when :length_symbols
          result = read_symbol_code_lengths(alphabet_size_limit)
          if result == DECODER_NEEDS_MORE_INPUT
            result = safe_read_symbol_code_lengths(alphabet_size_limit)
          end
          if result != DECODER_SUCCESS
            return {result, 0_u32}
          end

          if @space != 0
            return {FORMAT_HUFFMAN_SPACE, 0_u32}
          end
          table_size = Huffman.build_huffman_table(table, HUFFMAN_TABLE_BITS,
            @symbols_lists_array, @code_length_histo)
          @substate_huffman = :none
          return {DECODER_SUCCESS, table_size}
        end
      end
    end

    # ReadBlockLength (decode.c:933) — 3..39 bits.
    private def read_block_length(table : Slice(HuffmanCode)) : Int32
      code = read_symbol(table)
      offset, nbits = PREFIX_CODE_RANGES.unsafe_fetch(code)
      offset &+ @br.read_bits24(nbits).to_i32
    end

    # SafeReadBlockLength (decode.c:944): nil if there is not enough input.
    # WARNING: if @substate_read_block_length != :none, reading can't be
    # continued with read_block_length.
    private def safe_read_block_length(table : Slice(HuffmanCode)) : Int32?
      if @substate_read_block_length == :none
        index = safe_read_symbol(table)
        return nil unless index
        index = index.to_i32
      else
        index = @block_length_index
      end
      offset, nbits = PREFIX_CODE_RANGES.unsafe_fetch(index)
      bits = @br.safe_read_bits(nbits)
      if !bits
        @block_length_index = index
        @substate_read_block_length = :suffix
        return nil
      end
      @substate_read_block_length = :none
      offset &+ bits.to_i32
    end

    # ------------------------------------------------------------------
    # Context map / tree groups / block switches (decode.c:984-1324).

    # InverseMoveToFrontTransform (decode.c:984). mtf[k+1] addresses C's
    # mtf_u8[k] (bias 1, so mtf[0] plays the role of C's mtf_u8[-1]).
    private def inverse_move_to_front_transform(v : Bytes,
                                                v_len : Int32) : Nil
      upper_bound = @mtf_upper_bound
      mtf = @mtf
      i = 1
      # Reinitialize elements that could have been changed.
      lim = (upper_bound + 1) * 4
      while i <= lim
        mtf[i] = (i - 1).to_u8
        i += 1
      end

      # Transform the input.
      upper_bound = 0
      i = 0
      while i < v_len
        index = v.unsafe_fetch(i).to_i32
        value = mtf.unsafe_fetch(index + 1)
        upper_bound |= v.unsafe_fetch(i)
        v.unsafe_put(i, value)
        mtf.unsafe_put(0, value) # C's mtf_u8[-1] (bias 1)
        loop do
          index -= 1
          mtf.unsafe_put(index + 2, mtf.unsafe_fetch(index + 1))
          break unless index >= 0
        end
        i += 1
      end
      # Remember amount of elements to be reinitialized.
      @mtf_upper_bound = upper_bound >> 2
    end

    # BrotliDecoderHuffmanTreeGroupInit (state.c:163).
    private def huffman_tree_group_init(group : HuffmanTreeGroup,
                                        alphabet_size_max : Int32,
                                        alphabet_size_limit : Int32,
                                        ntrees : Int32) : Nil
      max_table_size = alphabet_size_limit + 376
      group.codes = Slice(HuffmanCode).new(ntrees * max_table_size) do
        HuffmanCode.new(0_u8, 0_u16)
      end
      group.htrees = Array(Slice(HuffmanCode)).new(ntrees) do
        Slice(HuffmanCode).empty
      end
      group.alphabet_size_max = alphabet_size_max
      group.alphabet_size_limit = alphabet_size_limit
      group.num_htrees = ntrees
    end

    # HuffmanTreeGroupDecode (decode.c:1022).
    private def huffman_tree_group_decode(group : HuffmanTreeGroup) : Int32
      if @substate_tree_group != :loop
        @next_offset = 0
        @htree_index = 0
        @substate_tree_group = :loop
      end
      while @htree_index < group.num_htrees
        code, table_size = read_huffman_code(group.alphabet_size_max,
          group.alphabet_size_limit, group.codes + @next_offset)
        return code if code != DECODER_SUCCESS
        group.htrees[@htree_index] = group.codes[@next_offset, table_size]
        @next_offset += table_size
        @htree_index += 1
      end
      @substate_tree_group = :none
      DECODER_SUCCESS
    end

    # DecodeContextMap (decode.c:1051). literal=true targets
    # @context_map/@num_literal_htrees, else @dist_context_map/@num_dist_htrees.
    private def decode_context_map(context_map_size : Int32, literal : Bool) : Int32
      loop do
        case @substate_context_map
        when :none
          result = decode_var_len_uint8
          return result if result != DECODER_SUCCESS
          if literal
            @num_literal_htrees = @varlen_uint8_value + 1
            @context_map = Bytes.new(context_map_size)
          else
            @num_dist_htrees = @varlen_uint8_value + 1
            @dist_context_map = Bytes.new(context_map_size)
          end
          @context_index = 0
          num_htrees = literal ? @num_literal_htrees : @num_dist_htrees
          if num_htrees <= 1
            (literal ? @context_map : @dist_context_map).not_nil!.fill(0)
            return DECODER_SUCCESS
          end
          @substate_context_map = :read_prefix
        when :read_prefix
          # In next stage ReadHuffmanCode uses at least 4 bits, so it is
          # safe to peek 4 bits ahead.
          bits = @br.safe_get_bits(5)
          return DECODER_NEEDS_MORE_INPUT unless bits
          if (bits & 1) != 0 # Use RLE for zeros.
            @max_run_length_prefix = ((bits >> 1) + 1).to_i32
            @br.drop_bits(5)
          else
            @max_run_length_prefix = 0
            @br.drop_bits(1)
          end
          @substate_context_map = :huffman
        when :huffman
          num_htrees = literal ? @num_literal_htrees : @num_dist_htrees
          alphabet_size = num_htrees + @max_run_length_prefix
          code, _ = read_huffman_code(alphabet_size, alphabet_size,
            @context_map_table)
          return code if code != DECODER_SUCCESS
          @code = 0xFFFF
          @substate_context_map = :decode
        when :decode
          map = (literal ? @context_map : @dist_context_map).not_nil!
          context_index = @context_index
          code = @code
          skip_preamble = code != 0xFFFF
          while context_index < context_map_size || skip_preamble
            if !skip_preamble
              c = safe_read_symbol(@context_map_table)
              if !c
                @code = 0xFFFF
                @context_index = context_index
                return DECODER_NEEDS_MORE_INPUT
              end
              code = c.to_i32
              if code == 0
                map.unsafe_put(context_index, 0_u8)
                context_index += 1
                next
              end
              if code > @max_run_length_prefix
                map.unsafe_put(context_index,
                  (code - @max_run_length_prefix).to_u8!)
                context_index += 1
                next
              end
            else
              skip_preamble = false
            end
            # RLE sub-stage.
            reps = @br.safe_read_bits(code)
            if !reps
              @code = code
              @context_index = context_index
              return DECODER_NEEDS_MORE_INPUT
            end
            reps += 1u64 << code
            if context_index + reps > context_map_size
              return FORMAT_CONTEXT_MAP_REPEAT
            end
            while reps != 0
              map.unsafe_put(context_index, 0_u8)
              context_index += 1
              reps -= 1
            end
          end
          @substate_context_map = :transform
        when :transform
          bits = @br.safe_read_bits(1)
          if !bits
            @substate_context_map = :transform
            return DECODER_NEEDS_MORE_INPUT
          end
          if bits != 0
            inverse_move_to_front_transform(
              (literal ? @context_map : @dist_context_map).not_nil!,
              context_map_size)
          end
          @substate_context_map = :none
          return DECODER_SUCCESS
        end
      end
    end

    # DecodeBlockTypeAndLength (decode.c:1180) — 3..54 bits.
    private def decode_block_type_and_length_internal(safe : Bool,
                                                      tree_type : Int32) : Int32
      max_block_type = @num_block_types[tree_type]
      type_tree = @block_type_trees + tree_type * HUFFMAN_MAX_SIZE_258
      len_tree = @block_len_trees + tree_type * HUFFMAN_MAX_SIZE_26
      rb_base = tree_type * 2
      return FORMAT_BLOCK_SWITCH if max_block_type <= 1

      # Read 0..15 + 3..39 bits.
      if !safe
        block_type = read_symbol(type_tree).to_i32
        @block_length[tree_type] = read_block_length(len_tree)
      else
        memento = @br.save_state
        bt = safe_read_symbol(type_tree)
        return DECODER_NEEDS_MORE_INPUT unless bt
        block_type = bt.to_i32
        bl = safe_read_block_length(len_tree)
        if !bl
          @substate_read_block_length = :none
          @br.restore_state(memento)
          return DECODER_NEEDS_MORE_INPUT
        end
        @block_length[tree_type] = bl
      end

      if block_type == 1
        block_type = @block_type_rb[rb_base + 1] + 1
      elsif block_type == 0
        block_type = @block_type_rb[rb_base]
      else
        block_type -= 2
      end
      if block_type >= max_block_type
        block_type -= max_block_type
      end
      @block_type_rb[rb_base] = @block_type_rb[rb_base + 1]
      @block_type_rb[rb_base + 1] = block_type
      DECODER_SUCCESS
    end

    # DetectTrivialLiteralBlockTypes (decode.c:1226).
    private def detect_trivial_literal_block_types : Nil
      8.times { |i| @trivial_literal_contexts[i] = 0 }
      context_map = @context_map.not_nil!
      i = 0
      while i < @num_block_types[0]
        offset = i << LITERAL_CONTEXT_BITS
        error = 0
        sample = context_map.unsafe_fetch(offset)
        j = 0
        while j < (1 << LITERAL_CONTEXT_BITS)
          error |= context_map.unsafe_fetch(offset + j) ^ sample
          j += 1
        end
        if error == 0
          @trivial_literal_contexts[i >> 5] |= 1u32 << (i & 31)
        end
        i += 1
      end
    end

    # PrepareLiteralDecoding (decode.c:1245).
    private def prepare_literal_decoding : Nil
      block_type = @block_type_rb[1]
      context_offset = block_type << LITERAL_CONTEXT_BITS
      @context_map_slice = @context_map.not_nil! + context_offset
      trivial = @trivial_literal_contexts[block_type >> 5]
      @trivial_literal_context = ((trivial >> (block_type & 31)) & 1) != 0
      @literal_htree = @literal_hgroup.htrees[@context_map_slice.not_nil![0]]
      context_mode = @context_modes.not_nil![block_type] & 3
      @context_lookup_offset = context_mode.to_i32 << 9
    end

    # BROTLI_CONTEXT(p1, p2, s->context_lookup).
    @[AlwaysInline]
    private def context_of(p1 : UInt8, p2 : UInt8) : Int32
      off = @context_lookup_offset
      CONTEXT_LOOKUP.unsafe_fetch(off + p1).to_i32 |
        CONTEXT_LOOKUP.unsafe_fetch(off + 256 + p2).to_i32
    end

    private def decode_literal_block_switch_internal(safe : Bool) : Int32
      result = decode_block_type_and_length_internal(safe, 0)
      return result if result != DECODER_SUCCESS
      prepare_literal_decoding
      DECODER_SUCCESS
    end

    private def decode_command_block_switch_internal(safe : Bool) : Int32
      result = decode_block_type_and_length_internal(safe, 1)
      return result if result != DECODER_SUCCESS
      @htree_command = @insert_copy_hgroup.htrees[@block_type_rb[3]]
      DECODER_SUCCESS
    end

    private def decode_distance_block_switch_internal(safe : Bool) : Int32
      result = decode_block_type_and_length_internal(safe, 2)
      return result if result != DECODER_SUCCESS
      @dist_context_map_slice = @dist_context_map.not_nil! +
                                (@block_type_rb[5] << DISTANCE_CONTEXT_BITS)
      @dist_htree_index = @dist_context_map_slice.not_nil![@distance_context].to_i32
      DECODER_SUCCESS
    end

    # ------------------------------------------------------------------
    # Ring buffer / output (decode.c:1326-1525).

    # UnwrittenBytes (decode.c:1326).
    private def unwritten_bytes(wrap : Bool) : Int64
      pos = wrap && @pos > @ringbuffer_size ? @ringbuffer_size : @pos
      @rb_roundtrips &* @ringbuffer_size &+ pos - @partial_pos_out
    end

    # WriteRingBuffer (decode.c:1336). Output is unbounded, so
    # NEEDS_MORE_OUTPUT is impossible and `force` only documents intent.
    private def write_ring_buffer(force : Bool) : Int32
      rb = @ringbuffer
      return DECODER_SUCCESS unless rb
      start = (@partial_pos_out & @ringbuffer_mask).to_i32!
      to_write = unwritten_bytes(true)
      if @meta_block_remaining_len < 0
        return FORMAT_BLOCK_LENGTH_1
      end
      if to_write > 0
        @output.write(rb[start, to_write.to_i32!])
      end
      @partial_pos_out += to_write
      # num_written == to_write (unbounded output).
      # Wrap ring buffer only if it has reached its maximal size.
      if @ringbuffer_size == (1 << @window_bits) && @pos >= @ringbuffer_size
        @pos -= @ringbuffer_size
        @rb_roundtrips += 1
        @should_wrap_ringbuffer = @pos != 0
      end
      DECODER_SUCCESS
    end

    # WrapRingBuffer (decode.c:1381).
    private def wrap_ring_buffer : Nil
      if @should_wrap_ringbuffer
        rb = @ringbuffer.not_nil!
        src = rb + @ringbuffer_size
        @pos.times { |k| rb.unsafe_put(k, src.unsafe_fetch(k)) }
        @should_wrap_ringbuffer = false
      end
    end

    # BrotliEnsureRingBuffer (decode.c:1395). Last two bytes are zeroed so
    # context calculation is uniform for the first two positions.
    private def ensure_ring_buffer : Nil
      return if @ringbuffer_size == @new_ringbuffer_size
      n = @new_ringbuffer_size
      rb = Bytes.new(n + RING_BUFFER_WRITE_AHEAD_SLACK)
      rb[n - 2] = 0
      rb[n - 1] = 0
      if old = @ringbuffer
        @pos.times { |k| rb.unsafe_put(k, old.unsafe_fetch(k)) }
      end
      @ringbuffer = rb
      @ringbuffer_size = n
      @ringbuffer_mask = n - 1
    end

    # SkipMetadataBlock (decode.c:1424) — callbacks not ported, bytes are
    # only drained from the stream.
    private def skip_metadata_block : Int32
      return DECODER_SUCCESS if @meta_block_remaining_len == 0

      # Drain accumulator.
      if @br.available_bits >= 8
        nbytes = @br.available_bits >> 3
        nbytes = @meta_block_remaining_len if nbytes > @meta_block_remaining_len
        @br.copy_bytes(Bytes.new(8), nbytes)
        @meta_block_remaining_len -= nbytes
        return DECODER_SUCCESS if @meta_block_remaining_len == 0
      end

      # Direct access to metadata is possible.
      nbytes = @br.remaining_bytes
      nbytes = @meta_block_remaining_len if nbytes > @meta_block_remaining_len
      if nbytes > 0
        @br.drop_bytes(nbytes)
        @meta_block_remaining_len -= nbytes
        return DECODER_SUCCESS if @meta_block_remaining_len == 0
      end

      DECODER_NEEDS_MORE_INPUT
    end

    # CopyUncompressedBlockToOutput (decode.c:1476).
    private def copy_uncompressed_block_to_output : Int32
      ensure_ring_buffer
      loop do
        case @substate_uncompressed
        when :none
          nbytes = @br.remaining_bytes
          nbytes = @meta_block_remaining_len if nbytes > @meta_block_remaining_len
          if @pos + nbytes > @ringbuffer_size
            nbytes = @ringbuffer_size - @pos
          end
          # Copy remaining bytes from the bit-reader window to ring-buffer.
          @br.copy_bytes(@ringbuffer.not_nil! + @pos, nbytes)
          @pos += nbytes
          @meta_block_remaining_len -= nbytes
          if @pos < (1 << @window_bits)
            if @meta_block_remaining_len == 0
              return DECODER_SUCCESS
            end
            return DECODER_NEEDS_MORE_INPUT
          end
          @substate_uncompressed = :write
        when :write
          result = write_ring_buffer(false)
          return result if result != DECODER_SUCCESS
          if @ringbuffer_size == (1 << @window_bits)
            @max_distance = @max_backward_distance
          end
          @substate_uncompressed = :none
        end
      end
    end

    # BrotliCalculateRingBufferSize (decode.c:1664); canny is always on.
    private def calculate_ring_buffer_size : Nil
      window_size = 1 << @window_bits
      # If maximum is already reached, no further extension is required.
      return if @ringbuffer_size == window_size
      # Metadata blocks do not touch ring buffer.
      return if @is_metadata

      min_size = @ringbuffer_size != 0 ? @ringbuffer_size : 1024
      output_size = (@ringbuffer ? @pos : 0) + @meta_block_remaining_len
      min_size = output_size if min_size < output_size

      # Reduce ring buffer size to save memory when server is unscrupulous.
      new_ringbuffer_size = window_size
      while (new_ringbuffer_size >> 1) >= min_size
        new_ringbuffer_size >>= 1
      end

      @new_ringbuffer_size = new_ringbuffer_size
    end

    # ReadContextModes (decode.c:1704) — 1..256 2-bit context modes.
    private def read_context_modes : Int32
      i = @loop_counter
      while i < @num_block_types[0]
        bits = @br.safe_read_bits(2)
        if !bits
          @loop_counter = i
          return DECODER_NEEDS_MORE_INPUT
        end
        @context_modes.not_nil![i] = bits.to_u8
        i += 1
      end
      DECODER_SUCCESS
    end

    # ------------------------------------------------------------------
    # Distances and commands (decode.c:1721-1964).

    # TakeDistanceFromRingBuffer (decode.c:1721).
    private def take_distance_from_ring_buffer : Nil
      offset = @distance_code - 3
      if @distance_code <= 3
        # Compensate double distance-ring-buffer roll for dictionary items.
        @distance_context = 1 >> @distance_code
        @distance_code = @dist_rb[(@dist_rb_idx - offset) & 3]
        @dist_rb_idx -= @distance_context
      else
        index_delta = 3
        base = @distance_code - 10
        if @distance_code < 10
          base = @distance_code - 4
        else
          index_delta = 2
        end
        # Unpack one of six 4-bit values.
        delta = ((0x605142 >> (4 * base)) & 0xF) - 3
        @distance_code = @dist_rb[(@dist_rb_idx + index_delta) & 3] + delta
        if @distance_code <= 0
          # A huge distance will cause a failure soon.
          @distance_code = 0x7FFFFFFF
        end
      end
    end

    # CalculateDistanceLut (decode.c:1835).
    private def calculate_distance_lut : Nil
      npostfix = @distance_postfix_bits
      ndirect = @num_direct_distance_codes
      alphabet_size_limit = @distance_hgroup.alphabet_size_limit
      postfix = 1 << npostfix
      i = NUM_DISTANCE_SHORT_CODES

      # Fill direct codes.
      j = 0
      while j < ndirect
        @dist_extra_bits[i] = 0
        @dist_offset[i] = j + 1
        i += 1
        j += 1
      end

      # Fill regular distance codes.
      bits = 1
      half = 0
      while i < alphabet_size_limit
        base = ndirect + ((((2 + half) << bits) - 4) << npostfix) + 1
        # Always fill the complete group.
        j = 0
        while j < postfix
          @dist_extra_bits[i] = bits.to_u8!
          @dist_offset[i] = base + j
          i += 1
          j += 1
        end
        bits += half
        half ^= 1
      end
    end

    # ReadDistanceInternal (decode.c:1870); nil on insufficient input.
    private def safe_read_distance : Bool
      memento = @br.save_state
      code0 = safe_read_symbol(@distance_hgroup.htrees[@dist_htree_index])
      return false unless code0
      code = code0.to_i32
      @block_length[2] -= 1
      # Convert the distance code to the actual distance by possibly
      # looking up past distances from the dist_rb.
      @distance_context = 0
      if code < NUM_DISTANCE_SHORT_CODES
        @distance_code = code
        take_distance_from_ring_buffer
        return true
      end
      bits = @br.safe_read_bits32(@dist_extra_bits.unsafe_fetch(code))
      if !bits
        @block_length[2] += 1
        @br.restore_state(memento)
        return false
      end
      @distance_code = @dist_offset.unsafe_fetch(code) &+
                       (bits << @distance_postfix_bits).to_i32
      true
    end

    private def read_distance : Nil
      code = read_symbol(@distance_hgroup.htrees[@dist_htree_index]).to_i32
      @block_length[2] -= 1
      @distance_context = 0
      if code < NUM_DISTANCE_SHORT_CODES
        @distance_code = code
        take_distance_from_ring_buffer
        return
      end
      bits = @br.read_bits32(@dist_extra_bits.unsafe_fetch(code))
      @distance_code = @dist_offset.unsafe_fetch(code) &+
                       (bits << @distance_postfix_bits).to_i32
    end

    # ReadCommandInternal (decode.c:1918); nil on insufficient input.
    # Returns the insert length.
    private def safe_read_command : Int32?
      memento = @br.save_state
      cmd0 = safe_read_symbol(@htree_command.not_nil!)
      return nil unless cmd0
      cmd_code = cmd0.to_i32
      v = CMD_LUT_OPTIMIZED.unsafe_fetch(cmd_code)
      @distance_code = v.distance_code.to_i32
      @distance_context = v.context.to_i32
      @dist_htree_index = @dist_context_map_slice.not_nil![@distance_context].to_i32
      insert_length = v.insert_len_offset.to_i32
      insert_len_extra = @br.safe_read_bits(v.insert_len_extra_bits)
      copy_length = @br.safe_read_bits(v.copy_len_extra_bits)
      if !insert_len_extra || !copy_length
        @br.restore_state(memento)
        return nil
      end
      @copy_length = copy_length.to_i32 + v.copy_len_offset
      @block_length[1] -= 1
      insert_length + insert_len_extra.to_i32
    end

    private def read_command : Int32
      cmd_code = read_symbol(@htree_command.not_nil!).to_i32
      v = CMD_LUT_OPTIMIZED.unsafe_fetch(cmd_code)
      @distance_code = v.distance_code.to_i32
      @distance_context = v.context.to_i32
      @dist_htree_index = @dist_context_map_slice.not_nil![@distance_context].to_i32
      insert_length = v.insert_len_offset.to_i32
      insert_len_extra = v.insert_len_extra_bits != 0 ?
        @br.read_bits24(v.insert_len_extra_bits.to_i32) : 0_u64
      copy_length = @br.read_bits24(v.copy_len_extra_bits.to_i32)
      @copy_length = copy_length.to_i32 + v.copy_len_offset
      @block_length[1] -= 1
      insert_length &+ insert_len_extra.to_i32
    end

    # CheckInputAmount (decode.c:1966).
    @[AlwaysInline]
    private def check_input_amount(safe : Bool) : Bool
      !safe ? @br.check_input_amount : true
    end

    private def memmove16(rb : Bytes, dst : Int32, src : Int32) : Nil
      tmp = uninitialized StaticArray(UInt8, 16)
      16.times { |k| tmp.to_unsafe[k] = rb.unsafe_fetch(src + k) }
      16.times { |k| rb.unsafe_put(dst + k, tmp.to_unsafe[k]) }
    end

    # saveStateAndReturn (decode.c:2393).
    private def save_commands_state(pos : Int32, i : Int32, result : Int32) : Int32
      @pos = pos
      @loop_counter = i
      result
    end

    # ------------------------------------------------------------------
    # ProcessCommandsInternal (decode.c:2005). The C goto labels become a
    # phase symbol re-dispatched by the while loop.

    private def process_commands_internal(safe : Bool) : Int32
      pos = @pos
      i = @loop_counter
      result = DECODER_SUCCESS

      unless check_input_amount(safe)
        return save_commands_state(pos, i, DECODER_NEEDS_MORE_INPUT)
      end
      @br.warmup? unless safe

      # Jump into state machine.
      phase = case @state
      when :command_begin                 then :begin
      when :command_inner                 then :inner
      when :command_post_decode_literals then :post_decode
      when :command_post_wrap_copy        then :post_wrap
      else
        return UNREACHABLE
      end

      jump = nil # :next_literal escape from the literal loops

      while true
        case phase
        when :begin
          @state = :command_begin if safe
          unless check_input_amount(safe)
            @state = :command_begin
            return save_commands_state(pos, i, DECODER_NEEDS_MORE_INPUT)
          end
          if @block_length[1] == 0
            # BROTLI_SAFE_WITH_STATUS(DecodeCommandBlockSwitch).
            status = safe ? decode_command_block_switch_internal(true)
                          : decode_command_block_switch_internal(false)
            if status != DECODER_SUCCESS
              return save_commands_state(pos, i, status)
            end
            phase = :begin # goto CommandBegin
            next
          end
          # Read the insert/copy length in the command.
          if safe
            insert_length = safe_read_command
            if !insert_length
              return save_commands_state(pos, i, DECODER_NEEDS_MORE_INPUT)
            end
            i = insert_length
          else
            i = read_command
          end
          if i == 0
            phase = :post_decode
            next
          end
          @meta_block_remaining_len -= i
          phase = :inner
        when :inner
          @state = :command_inner if safe
          # Read the literals in the command.
          if @trivial_literal_context
            literal_htree = @literal_htree.not_nil!
            rb = @ringbuffer.not_nil!
            pb = 0_u8
            pv = 0_u16
            unless safe
              pb, pv = preload_symbol(literal_htree)
            end
            if !safe
              # Hottest part of the decode: number of steps where all
              # checks evaluate to false.
              num_steps = i - 1
              if num_steps > 0 && num_steps > @block_length[0]
                num_steps = @block_length[0]
              end
              if @ringbuffer_size >= pos &&
                 (@ringbuffer_size - pos) <= num_steps
                num_steps = @ringbuffer_size - pos - 1
              end
              num_steps = 0 if num_steps < 0
              copies, pb, pv = copy_preloaded_symbols_to_u8(
                literal_htree, pb, pv, rb, pos, num_steps)
              pos += copies
              @block_length[0] -= copies
              i -= copies
              loop do
                unless check_input_amount(safe)
                  @state = :command_inner
                  return save_commands_state(pos, i, DECODER_NEEDS_MORE_INPUT)
                end
                if @block_length[0] == 0
                  jump = :next_literal
                  break
                end
                _, pb, pv = copy_preloaded_symbols_to_u8(
                  literal_htree, pb, pv, rb, pos, 1)
                @block_length[0] -= 1
                pos += 1
                if pos == @ringbuffer_size
                  @state = :command_inner_write
                  i -= 1
                  return save_commands_state(pos, i, DECODER_SUCCESS)
                end
                i -= 1
                break if i == 0
              end
            else # safe
              loop do
                if @block_length[0] == 0
                  jump = :next_literal
                  break
                end
                literal = safe_read_symbol(literal_htree)
                if !literal
                  return save_commands_state(pos, i, DECODER_NEEDS_MORE_INPUT)
                end
                rb.unsafe_put(pos, literal.to_u8!)
                @block_length[0] -= 1
                pos += 1
                if pos == @ringbuffer_size
                  @state = :command_inner_write
                  i -= 1
                  return save_commands_state(pos, i, DECODER_SUCCESS)
                end
                i -= 1
                break if i == 0
              end
            end
          else
            rb = @ringbuffer.not_nil!
            p1 = rb.unsafe_fetch((pos - 1) & @ringbuffer_mask)
            p2 = rb.unsafe_fetch((pos - 2) & @ringbuffer_mask)
            loop do
              unless check_input_amount(safe)
                @state = :command_inner
                return save_commands_state(pos, i, DECODER_NEEDS_MORE_INPUT)
              end
              if @block_length[0] == 0
                jump = :next_literal
                break
              end
              context = context_of(p1, p2)
              hc = @literal_hgroup.htrees[@context_map_slice.not_nil![context]]
              p2 = p1
              if safe
                literal = safe_read_symbol(hc)
                if !literal
                  return save_commands_state(pos, i, DECODER_NEEDS_MORE_INPUT)
                end
                p1 = literal.to_u8!
              else
                p1 = read_symbol(hc).to_u8!
              end
              rb.unsafe_put(pos, p1)
              @block_length[0] -= 1
              pos += 1
              if pos == @ringbuffer_size
                @state = :command_inner_write
                i -= 1
                return save_commands_state(pos, i, DECODER_SUCCESS)
              end
              i -= 1
              break if i == 0
            end
          end
          if jump == :next_literal
            jump = nil
            phase = :next_literal_block
            next
          end
          phase = :after_inner
        when :after_inner
          if @meta_block_remaining_len <= 0
            @state = :metablock_done
            return save_commands_state(pos, i, DECODER_SUCCESS)
          end
          phase = :post_decode
        when :post_decode
          @state = :command_post_decode_literals if safe
          if @distance_code >= 0
            # Implicit distance case.
            @distance_context = @distance_code != 0 ? 0 : 1
            @dist_rb_idx -= 1
            @distance_code = @dist_rb[@dist_rb_idx & 3]
          else
            # Read distance code in the command, unless it was implicit.
            if @block_length[2] == 0
              status = safe ? decode_distance_block_switch_internal(true)
                            : decode_distance_block_switch_internal(false)
              if status != DECODER_SUCCESS
                return save_commands_state(pos, i, status)
              end
            end
            if safe
              unless safe_read_distance
                return save_commands_state(pos, i, DECODER_NEEDS_MORE_INPUT)
              end
            else
              read_distance
            end
          end
          if @max_distance != @max_backward_distance
            @max_distance = pos < @max_backward_distance ? pos : @max_backward_distance
          end
          i = @copy_length
          # Apply copy of LZ77 back-reference, or static dictionary
          # reference if the distance is larger than the max LZ77 distance.
          if @distance_code > @max_distance
            if @distance_code > MAX_ALLOWED_DISTANCE
              return FORMAT_DISTANCE
            end
            # Compound dictionary is never attached (size 0).
            if i >= SHARED_MIN_DICTIONARY_WORD_LENGTH &&
               i <= SHARED_MAX_DICTIONARY_WORD_LENGTH
              size_bits = DICTIONARY_SIZE_BITS_BY_LENGTH.unsafe_fetch(i)
              offset = DICTIONARY_OFFSETS_BY_LENGTH.unsafe_fetch(i)
              address = @distance_code - @max_distance - 1
              mask = (1 << size_bits) - 1
              word_idx = address & mask
              transform_idx = address >> size_bits
              # Compensate double distance-ring-buffer roll.
              @dist_rb_idx += @distance_context
              offset += word_idx * i
              if size_bits == 0
                return FORMAT_DICTIONARY
              end
              if transform_idx < Transform::NUM_TRANSFORMS
                rb = @ringbuffer.not_nil!
                len = i
                if transform_idx == 0 # cutOffTransforms[0]
                  len.times { |k| rb.unsafe_put(pos + k, DICTIONARY_DATA.unsafe_fetch(offset + k)) }
                else
                  len = Transform.dictionary_word(rb, pos, DICTIONARY_DATA,
                    offset, i, transform_idx)
                  if len == 0 && @distance_code <= 120
                    return FORMAT_TRANSFORM
                  end
                end
                pos += len
                @meta_block_remaining_len -= len
                if pos >= @ringbuffer_size
                  @state = :command_post_write_1
                  return save_commands_state(pos, i, DECODER_SUCCESS)
                end
              else
                return FORMAT_TRANSFORM
              end
            else
              return FORMAT_DICTIONARY
            end
          else
            rb = @ringbuffer.not_nil!
            src_start = (pos - @distance_code) & @ringbuffer_mask
            dst_end = pos + i
            src_end = src_start + i
            # Update the recent distances cache.
            @dist_rb[@dist_rb_idx & 3] = @distance_code
            @dist_rb_idx += 1
            @meta_block_remaining_len -= i
            # Copy 16 bytes as a first guess (slack is guaranteed).
            memmove16(rb, pos, src_start)
            if src_end > pos && dst_end > src_start
              # Regions intersect.
              phase = :post_wrap
              next
            end
            if dst_end >= @ringbuffer_size || src_end >= @ringbuffer_size
              # At least one region wraps.
              phase = :post_wrap
              next
            end
            if i > 16
              if i > 32
                k = 16
                while k < i
                  rb.unsafe_put(pos + k, rb.unsafe_fetch(src_start + k))
                  k += 1
                end
              else
                memmove16(rb, pos + 16, src_start + 16)
              end
            end
            pos += i
          end
          if @meta_block_remaining_len <= 0
            # Next metablock, if any.
            @state = :metablock_done
            return save_commands_state(pos, i, DECODER_SUCCESS)
          else
            phase = :begin
          end
        when :post_wrap
          wrap_guard = @ringbuffer_size - pos
          while true
            i -= 1
            break if i < 0
            @ringbuffer.not_nil!.unsafe_put(pos,
              @ringbuffer.not_nil!.unsafe_fetch(
                (pos - @distance_code) & @ringbuffer_mask))
            pos += 1
            wrap_guard -= 1
            if wrap_guard == 0
              @state = :command_post_write_2
              return save_commands_state(pos, i, DECODER_SUCCESS)
            end
          end
          if @meta_block_remaining_len <= 0
            # Next metablock, if any.
            @state = :metablock_done
            return save_commands_state(pos, i, DECODER_SUCCESS)
          else
            phase = :begin
          end
        when :next_literal_block
          # BROTLI_SAFE_WITH_STATUS(DecodeLiteralBlockSwitch).
          status = safe ? decode_literal_block_switch_internal(true)
                        : decode_literal_block_switch_internal(false)
          if status != DECODER_SUCCESS
            return save_commands_state(pos, i, status)
          end
          phase = :inner
        end
      end
    end

    private def process_commands : Int32
      process_commands_internal(false)
    end

    private def safe_process_commands : Int32
      process_commands_internal(true)
    end

    # ------------------------------------------------------------------
    # Metablock state (state.c).

    # BrotliDecoderStateMetablockBegin (state.c:112).
    private def metablock_begin : Nil
      @meta_block_remaining_len = 0
      @block_length[0] = BLOCK_SIZE_CAP
      @block_length[1] = BLOCK_SIZE_CAP
      @block_length[2] = BLOCK_SIZE_CAP
      @num_block_types[0] = 1
      @num_block_types[1] = 1
      @num_block_types[2] = 1
      @block_type_rb[0] = 1
      @block_type_rb[1] = 0
      @block_type_rb[2] = 1
      @block_type_rb[3] = 0
      @block_type_rb[4] = 1
      @block_type_rb[5] = 0
      @context_map = nil
      @context_modes = nil
      @dist_context_map = nil
      @context_map_slice = nil
      @literal_htree = nil
      @dist_context_map_slice = nil
      @dist_htree_index = 0
      @context_lookup_offset = 0
    end

    # BrotliDecoderStateCleanupAfterMetablock (state.c:142).
    private def cleanup_after_metablock : Nil
      @context_modes = nil
      @context_map = nil
      @dist_context_map = nil
      @literal_hgroup = HuffmanTreeGroup.new
      @insert_copy_hgroup = HuffmanTreeGroup.new
      @distance_hgroup = HuffmanTreeGroup.new
    end
  end
end
