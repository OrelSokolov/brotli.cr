require "spec"
require "../src/brotli"

private def build_tree(counts : Array(UInt32), tree_limit = 15)
  length = counts.size
  tree = Slice(Brotli::Enc::HuffmanTree).new(2 * length + 1) do |i|
    Brotli::Enc::HuffmanTree.new
  end
  depth = Bytes.new(length)
  Brotli::Enc.create_huffman_tree(Slice.new(counts.to_unsafe, length), length,
                                  tree_limit, tree, depth)
  bits = Slice(UInt16).new(length)
  Brotli::Enc.convert_bit_depths_to_symbols(depth, length, bits)
  {depth, bits}
end

private def kraft_sum(depth : Bytes)
  sum = 0_i64
  depth.each do |d|
    sum += 1_i64 << (15 - d) if d > 0
  end
  sum
end

# Builds the decoder-side lookup table (huffman.cr) for the same depths and
# returns a decode(symbol_bits) probe using the decoder's table semantics.
private def decoder_table_for(depth : Bytes)
  flat = Slice(UInt16).new(720, 0xFFFF)
  count = Slice(UInt16).new(16, 0)
  15.downto(1) do |len|
    prev : Int32 = -1
    depth.each_with_index do |d, sym|
      next unless d == len
      if prev == -1
        flat[len] = sym.to_u16
      else
        flat[16 + prev] = sym.to_u16
      end
      prev = sym
      count[len] += 1
    end
  end
  table = Slice(Brotli::HuffmanCode).new(2048) { Brotli::HuffmanCode.new(0, 0) }
  Brotli::Huffman.build_huffman_table(table, 8, flat, count.dup)
  table
end

describe Brotli::Enc do
  describe ".create_huffman_tree" do
    it "builds optimal depths for uniform counts" do
      depth = build_tree([1, 1, 1, 1].map(&.to_u32))[0]
      depth.should eq Bytes[2, 2, 2, 2]
    end

    it "builds optimal depths for power-of-two weights" do
      depth = build_tree([1, 2, 4, 8].map(&.to_u32))[0]
      depth.should eq Bytes[3, 3, 2, 1]
    end

    it "assigns depth 1 to a single symbol" do
      depth = build_tree([0, 5, 0].map(&.to_u32))[0]
      depth.should eq Bytes[0, 1, 0]
    end

    it "produces a complete code (Kraft equality)" do
      rng = Random.new(7)
      50.times do
        counts = Array.new(rng.rand(2..64)) { rng.rand(1..1000).to_u32 }
        depth = build_tree(counts)[0]
        kraft_sum(depth).should eq 1_i64 << 15
      end
    end

    it "respects tree_limit on skewed distributions" do
      # Fibonacci-ish weights force depth > 15 without clamping.
      counts = [1_u32, 1_u32]
      18.times { counts << counts[-1] &+ counts[-2] }
      depth = build_tree(counts, 15)[0]
      depth.max.should be <= 15
      kraft_sum(depth).should be <= (1_i64 << 15)
      # 5-bit code-length tree limit variant
      depth5 = build_tree(counts, 5)[0]
      depth5.max.should be <= 5
    end
  end

  describe ".convert_bit_depths_to_symbols" do
    it "decodes back through the decoder's Huffman table" do
      rng = Random.new(11)
      30.times do
        counts = Array.new(rng.rand(2..70)) { rng.rand(1..500).to_u32 }
        depth, bits = build_tree(counts)
        table = decoder_table_for(depth)
        depth.each_with_index do |d, sym|
          next if d == 0
          code = bits[sym]
          if d <= 8
            e = table[code & 0xFF]
            e.bits.should eq d
            e.value.should eq sym
          end
        end
        # distinct codes across all symbols
        codes = depth.each_with_index.select { |d, _| d > 0 }
                     .map { |_, sym| bits[sym] }.to_a
        codes.size.should eq codes.uniq.size
      end
    end
  end

  describe ".write_huffman_tree" do
    it "RLE representation decodes back to the depth array" do
      cases = [
        Bytes[1, 2, 3, 4, 5],
        Bytes.new(64) { |i| (i < 30 ? 5 : 0).to_u8! },        # zero tail cut
        Bytes.new(64) { |i| 4.to_u8! },                        # long non-zero run
        Bytes.new(80) { |i| (i % 17 == 0 ? 2 : 0).to_u8! },    # sparse zeros
        Bytes.new(120) { |i| ((i // 7) % 6).to_u8! },          # varying values
      ]
      cases.each do |depth|
        tree = Bytes.new(depth.size + 16)
        extra = Bytes.new(depth.size + 16)
        size = Brotli::Enc.write_huffman_tree(depth, depth.size, tree, extra)
        # decode the (value, extra) stream back into depths; repeat chains
        # accumulate hierarchically exactly like the decoder does:
        # repeat = (repeat > 0 ? (repeat - 2) << bits : 0) + 3 + extra.
        reconstructed = [] of UInt8
        prev = Brotli::INITIAL_REPEATED_CODE_LENGTH.to_u8
        repeat_prev = 0
        repeat_zero = 0
        i = 0
        while i < size
          v = tree[i]
          if v == Brotli::REPEAT_PREVIOUS_CODE_LENGTH
            old = repeat_prev
            repeat_prev = (repeat_prev > 0 ? (repeat_prev - 2) << 2 : 0) + 3 + extra[i]
            (repeat_prev - old).times { reconstructed << prev }
          elsif v == Brotli::REPEAT_ZERO_CODE_LENGTH
            old = repeat_zero
            repeat_zero = (repeat_zero > 0 ? (repeat_zero - 2) << 3 : 0) + 3 + extra[i]
            (repeat_zero - old).times { reconstructed << 0_u8 }
          else
            reconstructed << v
            prev = v
            repeat_prev = 0
            repeat_zero = 0
          end
          i += 1
        end
        new_length = depth.size
        while new_length > 0 && depth[new_length - 1] == 0
          new_length -= 1
        end
        reconstructed.should eq depth[0, new_length].to_a
      end
    end
  end

  describe ".optimize_huffman_counts_for_rle" do
    it "leaves small histograms untouched" do
      counts = Slice[5_u32, 3_u32, 9_u32, 1_u32]
      before = counts.dup
      Brotli::Enc.optimize_huffman_counts_for_rle(counts.size, counts,
                                                  Bytes.new(counts.size))
      counts.should eq before
    end

    it "smoothes long equal strides" do
      counts = Slice.new(71) { |i| i < 70 ? 100_u32 : 1_u32 }
      before = counts.dup
      Brotli::Enc.optimize_huffman_counts_for_rle(counts.size, counts,
                                                  Bytes.new(counts.size))
      # The 70x100 stride is marked good_for_rle and gets averaged; the
      # original had no zeros so smoothing only equalizes runs, not invents
      # zeros: the set of distinct values must shrink or stay equal, and
      # the tail must be untouched.
      counts[-1].should eq 1
      counts.to_a.uniq.size.should be <= before.to_a.uniq.size
    end
  end
end
