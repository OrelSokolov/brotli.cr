# WOFF2 brotli-stream extractor (for differential testing of the Crystal
# decoder against real Google Fonts streams).
#
# In WOFF2 the whole transformed table data block is ONE brotli stream,
# located at header.compressed_offset with length header.compressed_length
# (see woff2_dec.cc: ConvertWOFF2ToTTF -> Woff2Uncompress). This tool
# parses the 48-byte header + table directory (+ collection directory)
# — a port of the subset of woff2_dec.cc needed to locate the stream —
# and writes the raw brotli bytes to stdout or a file.
#
# Usage: crystal run tools/woff2_brotli.cr -- file.woff2 [out.br]
#   Prints "offset=<o> length=<l> uncompressed=<n>" to stderr.


KNOWN_TAGS = [
  "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post", "cvt ",
  "fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT", "EBLC", "gasp",
  "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea", "vmtx", "BASE", "GDEF",
  "GPOS", "GSUB", "EBSC", "JSTF", "MATH", "CBDT", "CBLC", "COLR", "CPAL",
  "SVG ", "sbix", "acnt", "avar", "bdat", "bloc", "bsln", "cvar", "fdsc",
  "feat", "fmtx", "fvar", "gvar", "hsty", "just", "lcar", "mort", "morx",
  "opbd", "prop", "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill",
]

class Woff2ParseError < Exception
end

class Woff2Reader
  def initialize(@data : Bytes)
    @pos = 0
  end

  getter pos

  def u8 : Int32
    raise Woff2ParseError.new("EOF at #{@pos}") if @pos >= @data.size
    v = @data.unsafe_fetch(@pos)
    @pos += 1
    v.to_i32
  end

  def u16 : Int32
    (u8 << 8) | u8
  end

  def u32 : Int32
    (u8 << 24) | (u8 << 16) | (u8 << 8) | u8
  end

  def tag4 : String
    4.times.map { u8.chr }.join
  end

  def skip(n : Int32) : Nil
    @pos += n
    raise Woff2ParseError.new("EOF") if @pos > @data.size
  end

  # woff2 variable_length.cc Read255UShort.
  def read255_ushort : Int32
    code = u8
    case code
    when 253 then u16
    when 255 then u8 + 253
    when 254 then u8 + 506
    else          code
    end
  end

  # woff2 variable_length.cc ReadBase128.
  def read_base128 : Int32
    result = 0
    5.times do |i|
      code = u8
      raise Woff2ParseError.new("leading zero") if i == 0 && code == 0x80
      raise Woff2ParseError.new("overflow") if result & 0xfe000000 != 0
      result = (result << 7) | (code & 0x7f)
      return result if code & 0x80 == 0
    end
    raise Woff2ParseError.new("base128 too long")
  end
end

# Returns {compressed_offset, compressed_length, uncompressed_size}.
def woff2_brotli_span(data : Bytes) : {Int32, Int32, Int32}
  r = Woff2Reader.new(data)
  raise Woff2ParseError.new("bad signature") unless r.u32 == 0x774F4632
  flavor = r.u32
  raise Woff2ParseError.new("bad length") unless r.u32 == data.size
  num_tables = r.u16
  raise Woff2ParseError.new("no tables") if num_tables == 0
  r.skip(6)                          # reserved + totalSfntSize
  compressed_length = r.u32
  r.skip(4)                          # major/minor version
  r.skip(20)                         # meta + priv fields

  # Table directory (woff2_dec.cc ReadTableDirectory); we only need the
  # consumed size and uncompressed length, but must step through every
  # field faithfully. Transform rule: glyf/loca carry a transform_length
  # when xform_version == 0; all other tables when xform_version != 0.
  uncompressed_size = 0
  num_tables.times do
    flag_byte = r.u8
    idx = flag_byte & 0x3f
    tag = idx == 0x3f ? r.tag4 : KNOWN_TAGS.unsafe_fetch(idx)
    xform_version = (flag_byte >> 6) & 0x03
    dst_length = r.read_base128
    transform_length = dst_length
    transformed = tag == "glyf" || tag == "loca" ? xform_version == 0 : xform_version != 0
    if transformed
      transform_length = r.read_base128
    end
    uncompressed_size += transform_length
  end

  # Collection directory (ttcf flavors only).
  if flavor == 0x74746366
    r.skip(4) # header version
    num_fonts = r.read255_ushort
    num_fonts.times do
      num_font_tables = r.read255_ushort
      r.skip(4)
      num_font_tables.times { r.read255_ushort }
    end
  end

  {r.pos, compressed_length, uncompressed_size}
end

raise "usage: woff2_brotli file.woff2 [out.br]" if ARGV.empty?

data = File.read(ARGV[0]).to_slice
offset, length, uncompressed = woff2_brotli_span(data)
STDERR.puts "offset=#{offset} length=#{length} uncompressed=#{uncompressed}"
stream = data[offset, length]
if ARGV.size > 1
  File.write(ARGV[1], stream)
else
  STDOUT.write(stream)
end
