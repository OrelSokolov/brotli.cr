# Brotli decoder + encoder in pure Crystal, ported from google/brotli c/dec
# and c/enc (upstream pinned at 42a2ed4, 2026-09-30). Target use cases:
# WOFF2 font decoding for freetype.cr, asset compression (brotli encoder).
#
# Port rules (same as freetype.cr):
#   * one Crystal module per upstream C file, C symbol names kept as
#     method names where practical for diffing against upstream
#   * hot arithmetic uses wrapping ops (&+ &- &*) — the C code relies
#     on unsigned wraparound
#   * the caller guarantees >= SLACK_BYTES of readable bytes beyond the
#     logical end of input, so unaligned 64-bit window loads are safe
#     (mirrors BROTLI_FAST_INPUT_SLACK reasoning in c/dec/bit_reader.h)

require "./brotli/constants"
require "./brotli/types"
require "./brotli/bit_reader"
require "./brotli/tables_data"
require "./brotli/dictionary_data"
require "./brotli/transform"
require "./brotli/huffman"
require "./brotli/decoder"
require "./brotli/enc/enc_tables_data"
require "./brotli/enc/match_cost"
require "./brotli/enc/bit_writer"
require "./brotli/enc/params"
require "./brotli/enc/command"
require "./brotli/enc/entropy_encode"
require "./brotli/enc/bit_stream"
require "./brotli/enc/compress_fragment"
require "./brotli/enc/encoder"

module Brotli
  VERSION = "0.1.0" # keep in sync with shard.yml
end
