require "spec"
require "../src/brotli"

private def read_bit(bytes : Bytes, i : Int32) : Int32
  ((bytes[i >> 3] >> (i & 7)) & 1).to_i32
end

describe Brotli::Enc::BitWriter do
  it "writes LSB-first, increasing byte addresses (write_bits.h doc)" do
    w = Brotli::Enc::BitWriter.new(Bytes.new(4))
    w.write_bits(3, 0b101_u64)  # 3 bits already written case
    w.write_bits(5, 0b10011_u64)
    w.storage[0].should eq 0x9D # bits: 1,0,1 | 1,1,0,0,1
    w.storage[1].should eq 0
    w.pos.should eq 8
  end

  it "spans bytes correctly" do
    w = Brotli::Enc::BitWriter.new(Bytes.new(4))
    w.write_bits(6, 0xAA_u64)
    w.write_bits(10, 0x3FF_u64)
    # stream: 10101010 1111111111 -> byte0 = 0b10101010 low6 + high bits of 0x3FF
    w.pos.should eq 16
    bits = Array(Int32).new(16) { |i| read_bit(w.storage, i) }
    bits[0, 6].map(&.to_s).join.should eq "010101" # 0xAA & 0x3F, LSB first
    w.storage[2].should eq 0
  end

  it "roundtrips random bit sequences against an independent reader" do
    rng = Random.new(42)
    ops = [] of {Int32, UInt64}
    w = Brotli::Enc::BitWriter.new(Bytes.new(8192))
    500.times do
      n = rng.rand(1..56)
      v = rng.rand(UInt64::MAX) & ((1_u64 << n) &- 1)
      w.write_bits(n, v)
      ops << {n, v}
    end
    pos = 0
    ops.each do |n, v|
      val = 0_u64
      (0...n).each do |k|
        val |= read_bit(w.storage, pos + k).to_u64 << k
      end
      val.should eq v
      pos += n
    end
    w.pos.should eq pos
  end

  it "update_bits patches in place without moving pos" do
    w = Brotli::Enc::BitWriter.new(Bytes.new(8))
    w.write_bits(16, 0xFFFF_u64)
    w.update_bits(4, 0x0_u32, 4) # zero out bits 4..7
    w.storage[0].should eq 0x0F
    w.storage[1].should eq 0xFF
    w.pos.should eq 16
    w.update_bits(12, 0x123_u32, 8) # overwrite bits 8..19
    w.storage[1].should eq 0x23
    w.storage[2].should eq 0x01
  end

  it "rewind_bit_position masks the partial byte" do
    w = Brotli::Enc::BitWriter.new(Bytes.new(8))
    w.write_bits(12, 0xFFF_u64)
    w.rewind_bit_position(5)
    w.pos.should eq 5
    w.storage[0].should eq 0x1F # only low 5 bits survive
    w.write_bits(3, 0b000_u64)  # writing zeros keeps it masked
    w.storage[0].should eq 0x1F
  end
end
