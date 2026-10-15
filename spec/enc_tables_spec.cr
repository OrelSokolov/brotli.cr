require "../src/brotli/enc/enc_tables_data"

private def fnv1a64(p : Bytes) : UInt64
  h = 14695981039346656037_u64
  p.each do |b|
    h = (h ^ b) &* 1099511628211_u64
  end
  h
end

private def kraft_ok(depths : Bytes, max_depth : Int32) : Bool
  # Kraft inequality: sum(2^(max_depth - d)) <= 2^max_depth, at least one code.
  sum = 0_i64
  depths.each do |d|
    next if d == 0
    return false if d > max_depth
    sum &+= 1_i64 << (max_depth - d)
  end
  sum > 0 && sum <= (1_i64 << max_depth)
end

private def bits_fit_depths(depths : Bytes, bits : Slice) : Bool
  depths.each_with_index do |d, i|
    return false if d > 0 && (bits.unsafe_fetch(i).to_u64 >> d) != 0
  end
  true
end

private def bits_fit_depths(depths : Slice(UInt32), bits : Slice) : Bool
  depths.each_with_index do |d, i|
    return false if d > 0 && (bits.unsafe_fetch(i).to_u64 >> d) != 0
  end
  true
end

describe Brotli::Enc do
  it "blobs match FNV-1a64 checksums computed on the C side" do
    # Values printed by tools/dump_tables.c at generation time (upstream
    # 42a2ed4); regenerating from a different upstream revision must fail.
    fnv1a64(Brotli::Enc::DICT_HASH_WORDS_RAW).should eq 0x56b3ef6fdf1adae6_u64
    fnv1a64(Brotli::Enc::DICT_HASH_LENGTHS).should eq 0x73c5b12087461aaa_u64
    fnv1a64(Brotli::Enc::STATIC_DICTIONARY_BUCKETS_RAW).should eq 0x91ba745357aa25b9_u64
    fnv1a64(Brotli::Enc::STATIC_DICTIONARY_WORDS_LEN).should eq 0xc4b5d65666e30a49_u64
    fnv1a64(Brotli::Enc::STATIC_DICTIONARY_WORDS_TRANSFORM).should eq 0x2dfb4aa6c3898b15_u64
    fnv1a64(Brotli::Enc::STATIC_DICTIONARY_WORDS_IDX_RAW).should eq 0xbb128a657edb1019_u64
  end

  it "has expected table sizes" do
    Brotli::Enc::DICT_HASH_WORDS.size.should eq 32768
    Brotli::Enc::DICT_HASH_LENGTHS.size.should eq 32768
    Brotli::Enc::STATIC_DICTIONARY_BUCKETS.size.should eq 32768
    Brotli::Enc::STATIC_DICTIONARY_WORDS_LEN.size.should eq 31705
    Brotli::Enc::STATIC_DICTIONARY_WORDS_TRANSFORM.size.should eq 31705
    Brotli::Enc::STATIC_DICTIONARY_WORDS_IDX.size.should eq 31705
    Brotli::Enc::STATIC_COMMAND_CODE_DEPTH.size.should eq 704
    Brotli::Enc::STATIC_COMMAND_CODE_BITS.size.should eq 704
    Brotli::Enc::STATIC_DISTANCE_CODE_DEPTH.size.should eq 64
    Brotli::Enc::STATIC_DISTANCE_CODE_BITS.size.should eq 64
    Brotli::Enc::ZERO_REPS_BITS.size.should eq 704
    Brotli::Enc::ZERO_REPS_DEPTH.size.should eq 704
    Brotli::Enc::NON_ZERO_REPS_BITS.size.should eq 704
    Brotli::Enc::NON_ZERO_REPS_DEPTH.size.should eq 704
  end

  it "le_u16 decoding is little-endian" do
    # Cross-check a few entries against the raw bytes.
    raw = Brotli::Enc::DICT_HASH_WORDS_RAW
    words = Brotli::Enc::DICT_HASH_WORDS
    (0...words.size).each do |i|
      expected = raw.unsafe_fetch(i &* 2).to_u16 &+
                 (raw.unsafe_fetch(i &* 2 &+ 1).to_u16 << 8)
      words.unsafe_fetch(i).should eq expected
    end
  end

  it "dictionary hash entries are sane" do
    # One word per bucket: word index is per-length (max 2^11 slots).
    Brotli::Enc::DICT_HASH_WORDS.each do |w|
      w.should be <= 2047_u16
    end
    Brotli::Enc::DICT_HASH_LENGTHS.each do |l|
      l.should be <= 24_u8
    end
  end

  it "static dict LUT entries are sane" do
    buckets = Brotli::Enc::STATIC_DICTIONARY_BUCKETS
    buckets.each do |b|
      b.should be < 31706_u16 # offsets start at 1; 0 = empty bucket
    end
    # Slot 0 is a sentinel; real entries are 1..NUM_DICT_LUT_ITEMS-1.
    Brotli::Enc::STATIC_DICTIONARY_WORDS_LEN.each_with_index do |l, i|
      next if i == 0
      (l & 0x7F_u8).should be >= 4_u8
      (l & 0x7F_u8).should be <= 24_u8
    end
    Brotli::Enc::STATIC_DICTIONARY_WORDS_TRANSFORM.each_with_index do |t, i|
      next if i == 0
      t.should be < 121_u8 # NUM_TRANSFORMS
    end
    # Last word of the flat array ends its bucket.
    (Brotli::Enc::STATIC_DICTIONARY_WORDS_LEN.unsafe_fetch(31704) & 0x80_u8)
      .should_not eq 0
  end

  it "static entropy codes satisfy Kraft inequality and bit ranges" do
    kraft_ok(Brotli::Enc::CODE_LENGTH_DEPTH, 5).should be_true
    kraft_ok(Brotli::Enc::STATIC_COMMAND_CODE_DEPTH, 15).should be_true
    kraft_ok(Brotli::Enc::STATIC_DISTANCE_CODE_DEPTH, 15).should be_true
    bits_fit_depths(Brotli::Enc::CODE_LENGTH_DEPTH,
                    Brotli::Enc::CODE_LENGTH_BITS).should be_true
    bits_fit_depths(Brotli::Enc::STATIC_COMMAND_CODE_DEPTH,
                    Brotli::Enc::STATIC_COMMAND_CODE_BITS).should be_true
    bits_fit_depths(Brotli::Enc::STATIC_DISTANCE_CODE_DEPTH,
                    Brotli::Enc::STATIC_DISTANCE_CODE_BITS).should be_true
    # Reps tables are not prefix codes: their "depth" is the total bit count
    # of a repetition burst (RLE code + extra bits + repeated code), so only
    # the payload-fits-in-width property holds.
    bits_fit_depths(Brotli::Enc::ZERO_REPS_DEPTH, Brotli::Enc::ZERO_REPS_BITS).should be_true
    bits_fit_depths(Brotli::Enc::NON_ZERO_REPS_DEPTH, Brotli::Enc::NON_ZERO_REPS_BITS).should be_true
  end
end
