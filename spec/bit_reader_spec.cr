# Unit tests for Brotli::BitReader. Expected values come from an
# independent LSB-first bit extractor written directly in this spec
# (RefBits below) — the spec never calls the port to build expectations.
#
# Run: crystal spec

require "spec"
require "../src/brotli"

# Input buffer padded per the port contract: FAST_INPUT_SLACK+ readable
# bytes past the logical end.
def padded(bytes : Array(UInt8)) : Bytes
  s = Bytes.new(bytes.size + 64)
  bytes.each_with_index { |b, i| s[i] = b }
  s
end

# Reference: k-th bit read is bit (k % 8) of byte (k // 8), LSB-first.
class RefBits
  def initialize(@s : Bytes)
    @bit = 0
  end

  def take(n : Int32) : UInt64
    v = 0_u64
    n.times do |k|
      bit = (@s[@bit // 8] >> (@bit % 8)) & 1
      v |= bit.to_u64 << k
      @bit += 1
    end
    v
  end
end

describe Brotli::BitReader do
  it "reads sequential bit fields LSB-first (widths 1..24)" do
    # Deterministic pseudo-random bytes.
    bytes = Array(UInt8).new(32) { |i| ((i * 73 + 11) & 0xFF).to_u8 }
    buf = padded(bytes)
    br = Brotli::BitReader.new(buf, 0, bytes.size)
    ref = RefBits.new(buf)

    {1, 3, 4, 8, 15, 24, 9, 7, 16, 24, 2, 5}.each do |n|
      br.read_bits24(n).should eq ref.take(n)
    end
  end

  it "reads 32-bit fields across byte boundaries" do
    bytes = (0...16).map { |i| ((i * 157 + 29) & 0xFF).to_u8 }
    buf = padded(bytes)
    br = Brotli::BitReader.new(buf, 0, bytes.size)
    ref = RefBits.new(buf)
    {32, 32, 32, 17, 31, 20}.each do |n|
      br.read_bits32(n).should eq ref.take(n)
    end
  end

  it "peeks without advancing (get_bits)" do
    buf = padded([0xAB_u8, 0xCD_u8, 0xEF_u8, 0x12_u8, 0x34_u8])
    br = Brotli::BitReader.new(buf, 0, 5)
    br.warmup?.should be_true
    3.times { br.get_bits(12).should eq 0xDAB }
    br.take_bits(12).should eq 0xDAB
    br.get_bits(8).should eq 0xFC
  end

  it "reports end of input on safe reads" do
    buf = padded([0xFF_u8])
    br = Brotli::BitReader.new(buf, 0, 1)
    br.warmup?.should be_true
    br.safe_read_bits(8).should eq 0xFF
    br.safe_read_bits(1).should be_nil      # logical end reached
    br.get_bits_unmasked.should eq 0        # padding never leaks
  end

  it "warmup fails on empty input" do
    buf = padded([] of UInt8)
    Brotli::BitReader.new(buf, 0, 0).warmup?.should be_false
  end

  it "save/restore state rewinds speculative reads" do
    bytes = (0...8).map { |i| ((i * 31 + 7) & 0xFF).to_u8 }
    buf = padded(bytes)
    br = Brotli::BitReader.new(buf, 0, bytes.size)
    br.warmup?
    m = br.save_state
    a = br.safe_read_bits(24)
    b = br.safe_read_bits(24)
    br.restore_state(m)
    br.safe_read_bits(24).should eq a
    br.safe_read_bits(24).should eq b
  end

  it "jumps to byte boundary and validates pad bits" do
    buf = padded([0b0000_0111_u8, 0b1111_1111_u8, 0_u8])
    br = Brotli::BitReader.new(buf, 0, 3)
    br.warmup?
    br.take_bits(3).should eq 0b111
    br.jump_to_byte_boundary.should be_true  # upper 5 bits of byte0 are zero

    # read_bits (not take_bits): the accumulator is empty after the jump,
    # so the window must be refilled first — take_bits alone can't.
    br.read_bits24(3).should eq 0b111
    br.jump_to_byte_boundary.should be_false # upper 5 bits of byte1 are ones
  end

  it "unloads unconsumed whole bytes back to the input" do
    bytes = [0x5A_u8, 0xA5_u8, 0x37_u8, 0xC3_u8]
    buf = padded(bytes)
    br = Brotli::BitReader.new(buf, 0, bytes.size)
    br.warmup?
    br.fill_bit_window # warmup gives 1 byte; fill the window (4 more)
    br.take_bits(5).should eq 0x5A & 0x1F
    br.unload
    br.avail_in.should eq 3                  # 4 loaded, 5 bits consumed, 4 bytes pushed back... 3 remain unread
    br.available_bits.should eq 3
    br.take_bits(3).should eq 0x5A >> 5      # bits 5..7 of byte0 = 0b010
  end

  it "copies bytes from accumulator then input (copy_bytes)" do
    bytes = [0x11_u8, 0x22_u8, 0x33_u8, 0x44_u8, 0x55_u8, 0x66_u8]
    buf = padded(bytes)
    br = Brotli::BitReader.new(buf, 0, bytes.size)
    br.warmup?
    br.take_bits(4) # half of byte0 consumed; only 4 bits left in accumulator
    dest = Bytes.new(4)
    br.copy_bytes(dest, 4)
    # accumulator holds < 1 byte, so all 4 bytes come from the input
    # (starting at byte1), and the accumulator nibble is discarded:
    dest.should eq Bytes[0x22, 0x33, 0x44, 0x55]
    br.avail_in.should eq 1
  end

  it "guards the fast path with check_input_amount" do
    bytes = Array(UInt8).new(100) { |i| i.to_u8 }
    buf = padded(bytes)
    br = Brotli::BitReader.new(buf, 0, bytes.size)
    br.check_input_amount.should be_true          # 100 >= 28 bytes slack
    br.set_input(0, 10)
    br.check_input_amount.should be_false         # 10 < 28
  end
end
