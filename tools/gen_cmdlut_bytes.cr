# Regenerates src/brotli/cmd_lut_data.cr from the CMD_LUT oracle in
# src/brotli/tables_data.cr (dumped from upstream c/dec):
#
#   crystal run tools/gen_cmdlut_bytes.cr
#
# Encodes each CmdLut entry as 8 flat bytes (little-endian):
#   [0] insert_len_extra_bits  [1] copy_len_extra_bits
#   [2] distance_code (bit pattern)  [3] context
#   [4..5] insert_len_offset  [6..7] copy_len_offset

require "../src/brotli/tables_data"
require "../src/brotli/types"

HEADER = <<-HEAD
  # CMD_LUT_OPTIMIZED: flat-bytes twin of CMD_LUT (tables_data.cr, kept as
  # the oracle). The Array-of-704-CmdLut.new literal generates a const_init
  # with ~4k chained stores in ONE basic block; in --release (single LLVM
  # module) X86 instruction selection is superlinear on basic-block size,
  # which turned the release build into ~7 minutes of DAG combining.
  # Flat Bytes become a constant global, and the Array(CmdLut) is built by
  # a small loop at runtime — the giant basic block is gone.
  # Encoded per entry (8 bytes, little-endian):
  #   [0] insert_len_extra_bits  [1] copy_len_extra_bits
  #   [2] distance_code (bit pattern)  [3] context
  #   [4..5] insert_len_offset  [6..7] copy_len_offset
  # Generated from the CMD_LUT oracle by: crystal run tools/gen_cmdlut_bytes.cr

  require "./types"

  module Brotli
  HEAD

FOOTER = <<-FOOT


  # 704 entries (kCmdLut, decode.c). Loop-built from the flat bytes above;
  # field layout mirrors CmdLut.
  CMD_LUT_OPTIMIZED = Array.new(CMD_LUT_BYTES.size // 8) do |i|
    b = i &* 8
    CmdLut.new(
      CMD_LUT_BYTES.unsafe_fetch(b),
      CMD_LUT_BYTES.unsafe_fetch(b &+ 1),
      CMD_LUT_BYTES.unsafe_fetch(b &+ 2).to_i8!,
      CMD_LUT_BYTES.unsafe_fetch(b &+ 3),
      CMD_LUT_BYTES.unsafe_fetch(b &+ 4).to_u16 | (CMD_LUT_BYTES.unsafe_fetch(b &+ 5).to_u16 &* 256),
      CMD_LUT_BYTES.unsafe_fetch(b &+ 6).to_u16 | (CMD_LUT_BYTES.unsafe_fetch(b &+ 7).to_u16 &* 256),
    )
  end
end
FOOT

lut = Brotli::CMD_LUT
bytes = Bytes.new(lut.size &* 8)
lut.each_with_index do |e, i|
  b = i &* 8
  bytes[b] = e.insert_len_extra_bits
  bytes[b &+ 1] = e.copy_len_extra_bits
  bytes[b &+ 2] = e.distance_code.to_u8!
  bytes[b &+ 3] = e.context
  ins = e.insert_len_offset
  cpy = e.copy_len_offset
  bytes[b &+ 4] = (ins & 0xFF).to_u8!
  bytes[b &+ 5] = (ins >> 8).to_u8!
  bytes[b &+ 6] = (cpy & 0xFF).to_u8!
  bytes[b &+ 7] = (cpy >> 8).to_u8!
end

File.write("src/brotli/cmd_lut_data.cr", HEADER)
File.open("src/brotli/cmd_lut_data.cr", "a") do |f|
  f.puts "  CMD_LUT_BYTES = Bytes["
  i = 0
  while i < bytes.size
    f.puts "    " + bytes[i, 16].join(", ") + ","
    i += 16
  end
  f.puts "  ]"
  f.print FOOTER
end
puts "wrote src/brotli/cmd_lut_data.cr (#{lut.size} entries, #{bytes.size} bytes)"
