require "spec"
require "../src/brotli"

# Independent RFC 7932 reference: decodes a (npostfix=0, ndirect=0)
# distance code + extra bits back into the intermediate distance code.
private def ref_intermediate_code(code : Int32, extra : UInt32) : Int32
  return code if code < 16
  k = code - 16
  nbits = (k >> 1) + 1
  prefix = k & 1
  (((2 + prefix) << nbits) - 4) + extra.to_i32! + 16
end

describe Brotli::Enc do
  describe ".insert_length_code" do
    it "matches the kBrotliInsBase/Extra coverage exactly" do
      24.times do |i|
        base = Brotli::Enc::K_BROTLI_INS_BASE[i]
        span = 1_u32 << Brotli::Enc::K_BROTLI_INS_EXTRA[i]
        Brotli::Enc.insert_length_code(base.to_i32).should eq i
        Brotli::Enc.insert_length_code((base + span - 1).to_i32).should eq i
        if i < 23
          Brotli::Enc.insert_length_code((base + span).to_i32).should eq i + 1
        end
      end
      # out-of-table tail (code 23 covers up to 2^25-ish inserts)
      Brotli::Enc.insert_length_code(100_000).should eq 23
    end
  end

  describe ".copy_length_code" do
    it "matches the kBrotliCopyBase/Extra coverage exactly" do
      24.times do |i|
        base = Brotli::Enc::K_BROTLI_COPY_BASE[i]
        span = 1_u32 << Brotli::Enc::K_BROTLI_COPY_EXTRA[i]
        Brotli::Enc.copy_length_code(base.to_i32).should eq i
        Brotli::Enc.copy_length_code((base + span - 1).to_i32).should eq i
        if i < 23
          Brotli::Enc.copy_length_code((base + span).to_i32).should eq i + 1
        end
      end
      Brotli::Enc.copy_length_code(5000).should eq 23
    end
  end

  describe ".combine_length_codes" do
    it "cross-checks all 24x24 symbols against the decoder CMD_LUT" do
      lut = Brotli::CMD_LUT
      24.times do |ins|
        24.times do |copy|
          code = Brotli::Enc.combine_length_codes(
            ins.to_u16, copy.to_u16, false)
          e = lut[code]
          e.insert_len_offset.should eq Brotli::Enc::K_BROTLI_INS_BASE[ins]
          e.copy_len_offset.should eq Brotli::Enc::K_BROTLI_COPY_BASE[copy]
          e.insert_len_extra_bits.should eq Brotli::Enc::K_BROTLI_INS_EXTRA[ins]
          e.copy_len_extra_bits.should eq Brotli::Enc::K_BROTLI_COPY_EXTRA[copy]
          e.distance_code.should_not eq 0 # not a last-distance symbol
        end
      end
    end

    it "produces last-distance symbols (0..127) for small codes" do
      8.times do |ins|
        8.times do |copy|
          code = Brotli::Enc.combine_length_codes(
            ins.to_u16, copy.to_u16, true)
          code.should be < 128
          Brotli::CMD_LUT[code].distance_code.should eq 0
        end
      end
    end
  end

  describe ".prefix_encode_copy_distance" do
    it "matches the RFC 7932 distance table (npostfix=0, ndirect=0)" do
      # Known vectors: distance 1..4 -> symbols 16..17 with 1 extra bit.
      {1 => {16, 0}, 2 => {16, 1}, 3 => {17, 0}, 4 => {17, 1}}.each do |dist, (sym, extra)|
        code, ex = Brotli::Enc.prefix_encode_copy_distance((dist + 15).to_u64, 0_u32, 0_u32)
        (code & 0x3FF).should eq sym
        (code >> 10).should eq 1
        ex.should eq extra
      end
    end

    it "roundtrips against the reference decoder for many distances" do
      dists = (1..2000).to_a + (2000...Brotli::MAX_DISTANCE.to_i32).step(99_991).to_a
      dists.each do |dist|
        intermediate = dist + 15
        code, extra = Brotli::Enc.prefix_encode_copy_distance(
          intermediate.to_u64, 0, 0)
        low = code & 0x3FF
        low.should be >= 16
        ref_intermediate_code(low, extra).should eq intermediate
      end
    end

    it "short and direct codes pass through unchanged" do
      16.times do |c|
        code, extra = Brotli::Enc.prefix_encode_copy_distance(c.to_u64, 0_u32, 0_u32)
        code.should eq c
        extra.should eq 0
      end
      (0...30).each do |d|
        code, extra = Brotli::Enc.prefix_encode_copy_distance(
          (16 + d).to_u64, 30_u32, 0_u32)
        code.should eq 16 + d
        extra.should eq 0
      end
    end
  end

  describe Brotli::Enc::Command do
    it "restores the distance code it was built with" do
      dist = Brotli::Enc::DistanceParams.new
      # npostfix=2, ndirect=10 exercise the postfix arithmetic
      Brotli::Enc.init_distance_params(dist, 2, 10)
      codes = (0..40).to_a + (40..16_000_000).step(123_457).to_a
      codes.each do |c|
        cmd = Brotli::Enc::Command.new(5, 10, 0, c.to_u64, dist)
        cmd.restore_distance_code(dist).should eq c
      end
      # default params (0, 0)
      dist0 = Brotli::Enc::DistanceParams.new
      Brotli::Enc.init_distance_params(dist0, 0, 0)
      (1..500).each do |d|
        cmd = Brotli::Enc::Command.new(3, 8, 0, (d + 15).to_u64, dist0)
        cmd.restore_distance_code(dist0).should eq d + 15
      end
    end

    it "insert command has the C layout" do
      cmd = Brotli::Enc::Command.insert(1000)
      cmd.insert_len.should eq 1000
      cmd.copy_len.should eq 0           # low 25 bits of (4 << 25)
      cmd.copy_len_code.should eq 4      # + modifier 4
      cmd.dist_prefix.should eq 16       # BROTLI_NUM_DISTANCE_SHORT_CODES
      cmd.dist_extra.should eq 0
      cmd.cmd_prefix.should eq Brotli::Enc.length_code(1000, 4, false)
    end

    it "copy_len_code applies the signed modifier" do
      dist = Brotli::Enc::DistanceParams.new
      Brotli::Enc.init_distance_params(dist, 0, 0)
      cmd = Brotli::Enc::Command.new(0, 20, -2, 16_u64, dist)
      cmd.copy_len.should eq 20
      cmd.copy_len_code.should eq 18
      cmd2 = Brotli::Enc::Command.new(0, 20, 2, 16_u64, dist)
      cmd2.copy_len_code.should eq 22
    end
  end
end
