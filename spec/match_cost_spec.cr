require "spec"
require "../src/brotli"

describe Brotli::Enc do
  describe ".log2_floor_non_zero" do
    it "matches bit_length - 1" do
      {1, 2, 3, 255, 256, 65535, 65536, 1 << 40, (1 << 40) + 123}.each do |n|
        Brotli::Enc.log2_floor_non_zero(n).should eq n.bit_length - 1
      end
      Brotli::Enc.log2_floor_non_zero(1).should eq 0
      Brotli::Enc.log2_floor_non_zero(256).should eq 8
    end
  end

  describe ".fast_log2" do
    it "agrees with Math.log2" do
      Brotli::Enc.fast_log2(0).should eq 0.0
      Brotli::Enc.fast_log2(1).should eq 0.0 # table[1] = log2(1)
      (2...256).each do |i|
        Brotli::Enc.fast_log2(i).should be_close(Math.log2(i.to_f64), 1e-12)
      end
      Brotli::Enc.fast_log2(1000).should eq Math.log2(1000.0)
      Brotli::Enc.fast_log2((1 << 33) + 7).should eq Math.log2(((1 << 33) + 7).to_f64)
    end
  end

  describe ".find_match_length_with_limit" do
    it "matches a naive byte loop on random data" do
      rng = Random.new(3)
      200.times do
        data = Bytes.new(rng.rand(16..512)) { rng.rand(256).to_u8 }
        s1 = rng.rand(0...data.size // 2)
        s2 = rng.rand(0...data.size // 2)
        limit = rng.rand(0..(data.size - Math.max(s1, s2)))
        naive = 0
        while naive < limit && data[s1 + naive] == data[s2 + naive]
          naive += 1
        end
        Brotli::Enc.find_match_length_with_limit(data, s1, s2, limit)
          .should eq naive
      end
    end

    it "handles full overlap with itself" do
      data = Bytes.new(100) { |i| (i &* 7).to_u8! }
      Brotli::Enc.find_match_length_with_limit(data, 0, 0, 100).should eq 100
      Brotli::Enc.find_match_length_with_limit(data, 0, 0, 0).should eq 0
    end
  end

  describe ".mostly_utf8?" do
    it "accepts valid text and rejects binary" do
      utf8 = "héllo wörld — ünïcode ✓".to_slice
      binary = Bytes.new(64) { |i| (i &* 37 &+ 200).to_u8! }
      Brotli::Enc.mostly_utf8?(utf8, 0, utf8.size - 1, utf8.size, 0.75)
        .should be_true
      Brotli::Enc.mostly_utf8?(binary, 0, binary.size - 1, binary.size, 0.75)
        .should be_false
    end

    it "honours the fraction" do
      # 4 valid ASCII bytes followed by 4 invalid high bytes.
      mixed = Bytes[65, 66, 67, 68, 0xF0, 0xF1, 0xF2, 0xF3]
      Brotli::Enc.mostly_utf8?(mixed, 0, mixed.size - 1, mixed.size, 0.4)
        .should be_true
      Brotli::Enc.mostly_utf8?(mixed, 0, mixed.size - 1, mixed.size, 0.6)
        .should be_false
    end
  end
end
