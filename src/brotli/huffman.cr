# Port of c/dec/huffman.{h,c} — Huffman decoding table builders.
# Upstream: 42a2ed4. HuffmanCode keeps the C layout (bits + value);
# HuffmanTreeGroup mirrors the decode.c allocation (htrees point into
# one contiguous `codes` slice, like the C pointer arena).

module Brotli
  HUFFMAN_MAX_CODE_LENGTH          =  15
  HUFFMAN_MAX_SIZE_26              = 396 # BROTLI_NUM_BLOCK_LEN_SYMBOLS == 26
  HUFFMAN_MAX_SIZE_258             = 632 # BROTLI_MAX_BLOCK_TYPE_SYMBOLS == 258
  HUFFMAN_MAX_SIZE_272             = 646 # BROTLI_MAX_CONTEXT_MAP_SYMBOLS == 272
  HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH = 5

  struct HuffmanCode
    property bits : UInt8   # number of bits used for this symbol
    property value : UInt16 # symbol value or table offset

    def initialize(@bits : UInt8, @value : UInt16)
    end
  end

  # Contains a collection of Huffman trees with the same alphabet size.
  class HuffmanTreeGroup
    property htrees : Array(Slice(HuffmanCode)) = [] of Slice(HuffmanCode)
    property codes : Slice(HuffmanCode) = Slice(HuffmanCode).empty
    property alphabet_size_max : Int32 = 0
    property alphabet_size_limit : Int32 = 0
    property num_htrees : Int32 = 0
  end

  REVERSE_BITS_MAX = 8

  # C's symbol_lists pointer allows indices in [-16, 703]; the Crystal
  # slice is flat, so every C index is biased by this base (head slots
  # for code lengths 1..15 live at [0..14], links at [16..719]).
  SYMBOL_LISTS_BASE = 16

  # kReverseBits[x] = bit-reversal of x in 8 bits.
  K_REVERSE_BITS = begin
    t = StaticArray(UInt8, 256).new(0_u8)
    256.times do |i|
      v = 0_u8
      8.times do |b|
        v |= (((i >> b) & 1) << (7 - b)).to_u8
      end
      t[i] = v
    end
    t
  end

  module Huffman
    REVERSE_BITS_LOWEST = 1_u64 << (REVERSE_BITS_MAX - 1)

    @[AlwaysInline]
    def self.reverse_bits(num : UInt64) : UInt64
      K_REVERSE_BITS[num].to_u64
    end

    # Stores code in table[0], table[step], ..., table[end); end % step == 0.
    private def self.replicate_value(table : Slice(HuffmanCode), offset : Int32,
                                     step : Int32, end_ : Int32,
                                     code : HuffmanCode) : Nil
      while end_ > 0
        end_ -= step
        table[offset + end_] = code
      end
    end

    # Table width of the next 2nd level table.
    private def self.next_table_bit_size(count : Slice(UInt16), len : Int32,
                                         root_bits : Int32) : Int32
      left = 1 << (len - root_bits)
      while len < HUFFMAN_MAX_CODE_LENGTH
        left -= count[len]
        break if left <= 0
        len += 1
        left <<= 1
      end
      len - root_bits
    end

    # BrotliBuildCodeLengthsHuffmanTable: builds the table for the code
    # length alphabet itself. `code_lengths` has CODE_LENGTH_CODES entries;
    # `count` is the histogram (index 0 unused, 1..5 meaningful).
    def self.build_code_lengths_huffman_table(table : Slice(HuffmanCode),
                                              code_lengths : Slice(UInt8),
                                              count : Slice(UInt16)) : Nil
      sorted = Slice(Int32).new(CODE_LENGTH_CODES) # symbols sorted by code length
      offset = Slice(Int32).new(HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH + 1)

      # Generate offsets into sorted symbol table by code length.
      symbol = -1
      bits = 1
      while bits <= HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH
        symbol += count[bits]
        offset[bits] = symbol
        bits += 1
      end
      # Symbols with code length 0 are placed after all other symbols.
      offset[0] = CODE_LENGTH_CODES - 1

      # Sort symbols by length, by symbol order within each length.
      symbol = CODE_LENGTH_CODES
      while symbol != 0
        symbol -= 1
        sorted[offset[code_lengths[symbol]]] = symbol
        offset[code_lengths[symbol]] -= 1
      end

      table_size = 1 << HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH

      # Special case: all symbols but one have 0 code length.
      if offset[0] == 0
        code = HuffmanCode.new(0_u8, sorted[0].to_u16)
        table_size.times { |k| table[k] = code }
        return
      end

      # Fill in table.
      key = 0_u64
      key_step = REVERSE_BITS_LOWEST
      symbol = 0
      bits = 1
      step = 2
      loop do
        bits_count = count[bits]
        while bits_count != 0
          code = HuffmanCode.new(bits.to_u8, sorted[symbol].to_u16)
          symbol += 1
          replicate_value(table, reverse_bits(key).to_i32, step, table_size, code)
          key += key_step
          bits_count -= 1
        end
        step <<= 1
        key_step >>= 1
        bits += 1
        break if bits > HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH
      end
    end

    # BrotliBuildHuffmanTable: returns size of resulting table.
    # `symbol_lists` is indexed by (code_length - 16) like upstream;
    # each entry is the next symbol of that length, 0xFFFF terminator.
    def self.build_huffman_table(root_table : Slice(HuffmanCode), root_bits : Int32,
                                 symbol_lists : Slice(UInt16),
                                 count : Slice(UInt16)) : UInt32
      table_offset = 0 # next available space in table (index into root_table)
      max_length = -1
      while symbol_lists[SYMBOL_LISTS_BASE + max_length] == 0xFFFF
        max_length -= 1
      end
      max_length += HUFFMAN_MAX_CODE_LENGTH + 1

      table_offset = 0
      table_bits = root_bits
      table_size = 1 << table_bits
      total_size = table_size

      # Fill in the root table. Reduce the table size if possible,
      # and create the repetitions by memcpy.
      if table_bits > max_length
        table_bits = max_length
        table_size = 1 << table_bits
      end
      key = 0_u64
      key_step = REVERSE_BITS_LOWEST
      bits = 1
      step = 2
      loop do
        symbol = bits - (HUFFMAN_MAX_CODE_LENGTH + 1)
        bits_count = count[bits]
        while bits_count != 0
          symbol = symbol_lists[SYMBOL_LISTS_BASE + symbol].to_i32
          code = HuffmanCode.new(bits.to_u8, symbol.to_u16)
          replicate_value(root_table, table_offset + reverse_bits(key).to_i32,
                          step, table_size, code)
          key += key_step
          bits_count -= 1
        end
        step <<= 1
        key_step >>= 1
        bits += 1
        break if bits > table_bits
      end

      # If root_bits != table_bits then replicate to fill the remaining slots.
      while total_size != table_size
        (table_size).times do |i|
          root_table[table_offset + table_size + i] = root_table[table_offset + i]
        end
        table_size <<= 1
      end

      # Fill in 2nd level tables and add pointers to root table.
      key_step = REVERSE_BITS_LOWEST >> (root_bits - 1)
      sub_key : UInt64 = REVERSE_BITS_LOWEST << 1
      sub_key_step = REVERSE_BITS_LOWEST
      len = root_bits + 1
      step = 2
      while len <= max_length
        symbol = len - (HUFFMAN_MAX_CODE_LENGTH + 1)
        while count[len] != 0
          if sub_key == (REVERSE_BITS_LOWEST << 1)
            table_offset += table_size
            table_bits = next_table_bit_size(count, len, root_bits)
            table_size = 1 << table_bits
            total_size += table_size
            sub_key = reverse_bits(key)
            key += key_step
            sub_key_i = sub_key.to_i32
            root_table[sub_key_i] = HuffmanCode.new(
              (table_bits + root_bits).to_u8,
              (table_offset - sub_key_i).to_u16)
            sub_key = 0
          end
          symbol = symbol_lists[SYMBOL_LISTS_BASE + symbol].to_i32
          code = HuffmanCode.new((len - root_bits).to_u8, symbol.to_u16)
          replicate_value(root_table, table_offset + reverse_bits(sub_key).to_i32,
                          step, table_size, code)
          sub_key += sub_key_step
          count[len] -= 1
        end
        step <<= 1
        sub_key_step >>= 1
        len += 1
      end
      total_size.to_u32
    end

    # BrotliBuildSimpleHuffmanTable. num_symbols semantics (C comments):
    # 0 => 1 symbol; 1 => 2; 2 => 3; 3 => 4 with lengths [2,2,2,2];
    # 4 => 4 with lengths [1,2,3,3]. `val` is modified (sorted) in place.
    def self.build_simple_huffman_table(table : Slice(HuffmanCode), root_bits : Int32,
                                        val : Slice(UInt16),
                                        num_symbols : UInt32) : UInt32
      table_size = 1
      goal_size = 1_u32 << root_bits
      case num_symbols
      when 0
        table[0] = HuffmanCode.new(0_u8, val[0])
      when 1
        if val[1] > val[0]
          table[0] = HuffmanCode.new(1_u8, val[0])
          table[1] = HuffmanCode.new(1_u8, val[1])
        else
          table[0] = HuffmanCode.new(1_u8, val[1])
          table[1] = HuffmanCode.new(1_u8, val[0])
        end
        table_size = 2
      when 2
        table[0] = HuffmanCode.new(1_u8, val[0])
        table[2] = HuffmanCode.new(1_u8, val[0])
        if val[2] > val[1]
          table[1] = HuffmanCode.new(2_u8, val[1])
          table[3] = HuffmanCode.new(2_u8, val[2])
        else
          table[1] = HuffmanCode.new(2_u8, val[2])
          table[3] = HuffmanCode.new(2_u8, val[1])
        end
        table_size = 4
      when 3
        3.times do |i|
          (i + 1...4).each do |k|
            if val[k] < val[i]
              val[k], val[i] = val[i], val[k]
            end
          end
        end
        table[0] = HuffmanCode.new(2_u8, val[0])
        table[2] = HuffmanCode.new(2_u8, val[1])
        table[1] = HuffmanCode.new(2_u8, val[2])
        table[3] = HuffmanCode.new(2_u8, val[3])
        table_size = 4
      when 4
        if val[3] < val[2]
          val[3], val[2] = val[2], val[3]
        end
        table[0] = HuffmanCode.new(1_u8, val[0])
        table[1] = HuffmanCode.new(2_u8, val[1])
        table[2] = HuffmanCode.new(1_u8, val[0])
        table[3] = HuffmanCode.new(3_u8, val[2])
        table[4] = HuffmanCode.new(1_u8, val[0])
        table[5] = HuffmanCode.new(2_u8, val[1])
        table[6] = HuffmanCode.new(1_u8, val[0])
        table[7] = HuffmanCode.new(3_u8, val[3])
        table_size = 8
      end
      while table_size != goal_size
        table_size.times { |i| table[table_size + i] = table[i] }
        table_size <<= 1
      end
      goal_size
    end
  end
end
