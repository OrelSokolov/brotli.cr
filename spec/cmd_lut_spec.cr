require "spec"
require "../src/brotli/tables_data"
require "../src/brotli/cmd_lut_data"

# CMD_LUT (tables_data.cr) is the oracle dumped from upstream c/dec;
# CMD_LUT_OPTIMIZED (cmd_lut_data.cr) is the flat-bytes twin used by the
# decoder — the Array-of-structs literal made release builds take ~7 min
# of LLVM instruction selection (one ~4k-store basic block).
describe Brotli::CMD_LUT_OPTIMIZED do
  it "has the same size as the CMD_LUT oracle" do
    Brotli::CMD_LUT_OPTIMIZED.size.should eq Brotli::CMD_LUT.size
    Brotli::CMD_LUT.size.should eq 704 # kCmdLut, decode.c
  end

  it "matches every oracle entry field by field" do
    Brotli::CMD_LUT.each_with_index do |oracle, i|
      v = Brotli::CMD_LUT_OPTIMIZED.unsafe_fetch(i)
      v.insert_len_extra_bits.should eq oracle.insert_len_extra_bits
      v.copy_len_extra_bits.should eq oracle.copy_len_extra_bits
      v.distance_code.should eq oracle.distance_code
      v.context.should eq oracle.context
      v.insert_len_offset.should eq oracle.insert_len_offset
      v.copy_len_offset.should eq oracle.copy_len_offset
    end
  end
end
