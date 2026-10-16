# brotli.cr

Brotli ([RFC 7932](https://www.rfc-editor.org/rfc/rfc7932)) decoder and
encoder in pure Crystal, ported file-by-file from
[google/brotli](https://github.com/google/brotli) (`c/dec`, `c/enc`).

No C bindings and no runtime dependencies — the static dictionary,
transforms and all tables are embedded.

## Features

- **Complete decoder**: meta-block state machine, static dictionary with
  word transforms, context modeling, all prefix-code variants.
  Originally built for [freetype.cr](https://github.com/OrelSokolov/freetype.cr)
  WOFF2 font decoding.
- **Complete encoder**: quality 0–11 (one-pass and two-pass fragment
  encoders, greedy/lazy hash matchers H2–H54, the q4–q9 metablock
  pipeline with block splitting and context clustering, q10/q11 Zopfli
  DP), window sizes lgwin 10–22, input modes generic / text / font.
- One-shot APIs: whole input in memory, whole output returned.
  Streaming (incremental) APIs are not implemented.

## Installation

Add to `shard.yml`:

```yaml
dependencies:
  brotli:
    github: OrelSokolov/brotli.cr
```

Then `shards install` and `require "brotli"`.
Built and tested with Crystal 1.21.

## Usage

### Decode

```crystal
require "brotli"

compressed = File.read("data.br")

begin
  data = Brotli::Decoder.new.decode(compressed.to_slice)
rescue e : Brotli::DecodeError
  puts "decode error #{e.code}"   # code 2 (NEEDS_MORE_INPUT) = truncated stream
end
```

### Encode

```crystal
require "brotli"

data = File.read("data.txt").to_slice

# quality 0..11, lgwin 10..22, mode :generic/:text/:font
compressed = Brotli::Enc::Encoder.new(quality: 9).encode(data)

# roundtrip
Brotli::Decoder.new.decode(compressed) == data  # => true
```

### CLI

```console
$ crystal bin/brotli_decode input.br [output]      # no output arg -> stdout
$ crystal bin/brotli_encode input [output] -q 11 -w 22 -m text
```

`brotli_encode` flags: `-q N` quality (default 11), `-w N` window bits
(default 22), `-m generic|text|font`.

## Status

Everything is validated by double roundtrips — every produced stream is
decoded byte-exactly both by the reference C decoder (used as an oracle)
and by this library's own decoder:

- upstream brotli testdata: 24 files × q0–q11
- Silesia corpus: 13 files (~211 MB) × q0–q11
- 173 WOFF2 fonts, an asset corpus (js/css/json/svg/UTF-8 text) × q0–q11
- edge cases: empty, 1 byte, random data, RLE, a 105 MB file (window
  wraparound at q0/q1), and a full lgwin 10–22 sweep (728/728)
- `crystal spec`: 56 examples; differential decoder tests: 45/45

Compression ratio vs the C `brotli` CLI at equal quality (Silesia,
size sums): −0.5% (q0) to +4.0% (q11); text-like inputs at q4–q10 are
byte-identical to C. The remaining gap on large binaries comes from
simplified per-window-fragment metablocking.

Throughput on Silesia (280 MB, single-threaded, release builds):
q1 2.4×, q5 1.4×, q9 0.5×, q11 0.9× of the C encoder's time
(faster than C at q9/q11 — see above).

## Project layout

- `src/brotli/` — decoder (`decoder.cr`, `huffman.cr`, `bit_reader.cr`,
  `transform.cr`, …) and encoder (`src/brotli/enc/`)
- `bin/` — `brotli_decode`, `brotli_encode` CLI frontends
- `tools/` — test drivers: `diff_test.sh` (decoder differential),
  `encode_test.sh` / `encode_full_test.sh` (double roundtrip),
  `lgwin_test.sh`, `encode_ratio.sh` (size vs C), `bench.sh` /
  `enc_bench.sh` (decoder/encoder benchmarks)
- `upstream/` — read-only clone of google/brotli used as the oracle
- `PLAN.md` — phase-by-phase porting log (in Russian)

## License

MIT — see `LICENSE`. The port follows the google/brotli sources
(MIT-licensed) closely; the reference clone lives in `upstream/brotli`.
