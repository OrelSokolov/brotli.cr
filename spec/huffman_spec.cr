require "spec"
require "../src/brotli"

describe Brotli::Huffman do
  describe "build_simple_huffman_table" do
    it "handles 1 symbol (num_symbols=0): all entries are 0-bit" do
      t = Slice(Brotli::HuffmanCode).new(16) { Brotli::HuffmanCode.new(0_u8, 0_u16) }
      Brotli::Huffman.build_simple_huffman_table(t, 4, Slice[7u16, 0u16, 0u16, 0u16], 0u32)
        .should eq 16
      t.each { |c| c.bits.should eq 0; c.value.should eq 7 }
    end

    it "orders 2 symbols by value" do
      t = Slice(Brotli::HuffmanCode).new(8) { Brotli::HuffmanCode.new(0_u8, 0_u16) }
      Brotli::Huffman.build_simple_huffman_table(t, 3, Slice[9u16, 3u16, 0u16, 0u16], 1u32)
        .should eq 8
      t[0].value.should eq 3 # smaller value gets code 0
      t[0].bits.should eq 1
      t[1].value.should eq 9
    end

    it "handles 3 symbols: one 1-bit and two 2-bit" do
      t = Slice(Brotli::HuffmanCode).new(8) { Brotli::HuffmanCode.new(0_u8, 0_u16) }
      Brotli::Huffman.build_simple_huffman_table(t, 3, Slice[1u16, 2u16, 3u16, 0u16], 2u32)
        .should eq 8
      # layout: table[0],[2] = val0 (1 bit); [1],[3] = val1/val2 (2 bits)
      t[0].value.should eq 1
      t[0].bits.should eq 1
      t[2].value.should eq 1
      t[1].bits.should eq 2
      t[3].bits.should eq 2
      {t[1].value, t[3].value}.should eq({2, 3})
    end

    it "handles 4 symbols with lengths [2,2,2,2] sorted ascending" do
      t = Slice(Brotli::HuffmanCode).new(8) { Brotli::HuffmanCode.new(0_u8, 0_u16) }
      Brotli::Huffman.build_simple_huffman_table(t, 3, Slice[4u16, 1u16, 3u16, 2u16], 3u32)
        .should eq 8
      t.each { |c| c.bits.should eq 2 }
      # canonical order after in-place sort: table[0],[2],[1],[3] = 1,2,3,4
      t[0].value.should eq 1
      t[2].value.should eq 2
      t[1].value.should eq 3
      t[3].value.should eq 4
    end

    it "handles 4 symbols with lengths [1,2,3,3]" do
      t = Slice(Brotli::HuffmanCode).new(8) { Brotli::HuffmanCode.new(0_u8, 0_u16) }
      Brotli::Huffman.build_simple_huffman_table(t, 3, Slice[1u16, 2u16, 5u16, 4u16], 4u32)
        .should eq 8
      {t[0].bits, t[1].bits, t[2].bits, t[3].bits,
       t[4].bits, t[5].bits, t[6].bits, t[7].bits}.should eq(
        {1, 2, 1, 3, 1, 2, 1, 3})
      t[0].value.should eq 1 # 1-bit symbol replicated at even slots
      t[3].value.should eq 4 # last two sorted: 4 then 5
      t[7].value.should eq 5
    end
  end

  describe "build_code_lengths_huffman_table" do
    it "builds a table where every code decodes back to its symbol" do
      # code lengths for the 18 code-length symbols themselves:
      # one 1-bit code + four 3-bit codes = complete code (1/2 + 4/8).
      lens = Slice(UInt8).new(18, 0)
      lens[0] = 1; lens[1] = 3; lens[2] = 3; lens[3] = 3; lens[4] = 3
      count = Slice(UInt16).new(6)
      lens.each { |l| count[l] += 1 }

      t = Slice(Brotli::HuffmanCode).new(32) { Brotli::HuffmanCode.new(0_u8, 0_u16) }
      Brotli::Huffman.build_code_lengths_huffman_table(t, lens, count)

      # canonical codes: len1 -> symbol0 = "0"; len3 symbols 1..5 get
      # 100,101,110,111,0000... wait: 5 symbols of len 3 over codes
      # 100..111 plus wrap — instead of hand-computing, decode by
      # walking the table: for every index i, t[i].bits must be a valid
      # length and the code (reversed i, t[i].bits bits) must map to
      # the same symbol for all replicated entries.
      32.times do |i|
        c = t[i]
        lens[c.value].should eq c.bits # symbol's length matches entry bits
      end
      # every symbol appears (0 = 1-bit code, 1..4 = 3-bit codes)
      syms = Set.new(t.map(&.value))
      (0...5).each { |s| syms.should contain(s) }
    end

    it "all-but-one-zero-length special case fills the whole table" do
      lens = Slice(UInt8).new(18, 0)
      lens[17] = 5
      count = Slice(UInt16).new(6)
      lens.each { |l| count[l] += 1 }
      t = Slice(Brotli::HuffmanCode).new(32) { Brotli::HuffmanCode.new(0_u8, 0_u16) }
      Brotli::Huffman.build_code_lengths_huffman_table(t, lens, count)
      t.each do |c|
        c.bits.should eq 0
        c.value.should eq 17
      end
    end
  end

  describe "build_huffman_table" do
    it "builds a two-level table for codes longer than root_bits" do
      # 6 symbols with lengths {2, 2, 4, 4, 4, 4}: complete code
      # (1/4 + 1/4 + 4/16 == 1); root_bits 3 forces a 2nd level table.
      lens = {2, 2, 4, 4, 4, 4}
      # Decoder's symbol_lists layout (Brotli::SYMBOL_LISTS_BASE = 16): heads for
      # code lengths 1..15 live at [len], symbol chains at [16 + symbol];
      # chains are in ascending symbol order, 0xFFFF terminates.
      flat = Slice(UInt16).new(Brotli::SYMBOL_LISTS_BASE + lens.size, 0xFFFF)
      count = Slice(UInt16).new(16, 0)
      lens.each { |l| count[l] += 1 }
      (1..15).each do |l|
        chain = [] of Int32
        lens.each_with_index { |ll, s| chain << s if ll == l }
        next if chain.empty?
        flat[l] = chain[0].to_u16
        (0...chain.size - 1).each do |k|
          flat[Brotli::SYMBOL_LISTS_BASE + chain[k]] = chain[k + 1].to_u16
        end
        flat[Brotli::SYMBOL_LISTS_BASE + chain[-1]] = 0xFFFF
      end

      t = Slice(Brotli::HuffmanCode).new(Brotli::HUFFMAN_MAX_SIZE_26) do
        Brotli::HuffmanCode.new(0_u8, 0_u16)
      end
      size = Brotli::Huffman.build_huffman_table(t, 3, flat, count)
      # 8 root entries + two 2-entry 2nd level tables (one per root
      # pointer: 100x -> symbols 2,3; 101x -> symbols 4,5).
      size.should eq 12

      # Canonical codes: sym0/sym1 len2 -> 00, 01; sym2..5 len4 ->
      # 1000, 1001, 1010, 1011. Brotli reads bits LSB-first, so a table
      # index is the bit-reversal of the code prefix.
      rev = ->(v : Int32, n : Int32) {
        r = 0
        n.times { |b| r |= ((v >> b) & 1) << (n - 1 - b) }
        r
      }
      # len-2 symbols at root: "00" -> idx 0, "01" -> idx 2 (bits are
      # read LSB-first; index = code string reversed within its length).
      t[rev.call(0b00, 2)].value.should eq 0
      t[rev.call(0b00, 2)].bits.should eq 2
      t[rev.call(0b01, 2)].value.should eq 1
      # 1000/1001 share prefix 100 -> root idx 1 is a pointer entry.
      entry = t[rev.call(0b100, 3)]
      entry.bits.should be > 3
      second = rev.call(0b100, 3) + entry.value
      t[second + rev.call(0b00, 1)].value.should eq 2 # 1000
      t[second + rev.call(0b01, 1)].value.should eq 3 # 1001
      # 1010/1011 share prefix 101 -> root idx 5.
      entry5 = t[rev.call(0b101, 3)]
      second5 = rev.call(0b101, 3) + entry5.value
      t[second5 + rev.call(0b10, 1)].value.should eq 4 # 1010
      t[second5 + rev.call(0b11, 1)].value.should eq 5 # 1011
    end
  end
end
