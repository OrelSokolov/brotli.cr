# Port of c/enc/command.{c,h} and prefix.h. Upstream: 42a2ed4.

module Brotli
  module Enc
    K_BROTLI_INS_BASE = Slice[
      0_u32, 1_u32, 2_u32, 3_u32, 4_u32, 5_u32, 6_u32, 8_u32, 10_u32, 14_u32,
      18_u32, 26_u32, 34_u32, 50_u32, 66_u32, 98_u32, 130_u32, 194_u32,
      322_u32, 578_u32, 1090_u32, 2114_u32, 6210_u32, 22594_u32]
    K_BROTLI_INS_EXTRA = Slice[
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 1_u32, 1_u32, 2_u32, 2_u32,
      3_u32, 3_u32, 4_u32, 4_u32, 5_u32, 5_u32, 6_u32, 7_u32, 8_u32, 9_u32,
      10_u32, 12_u32, 14_u32, 24_u32]
    K_BROTLI_COPY_BASE = Slice[
      2_u32, 3_u32, 4_u32, 5_u32, 6_u32, 7_u32, 8_u32, 9_u32, 10_u32, 12_u32,
      14_u32, 18_u32, 22_u32, 30_u32, 38_u32, 54_u32, 70_u32, 102_u32,
      134_u32, 198_u32, 326_u32, 582_u32, 1094_u32, 2118_u32]
    K_BROTLI_COPY_EXTRA = Slice[
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 1_u32, 1_u32,
      2_u32, 2_u32, 3_u32, 3_u32, 4_u32, 4_u32, 5_u32, 5_u32, 6_u32, 7_u32,
      8_u32, 9_u32, 10_u32, 24_u32]

    def self.insert_length_code(insertlen : Int32) : UInt16
      if insertlen < 6
        insertlen.to_u16
      elsif insertlen < 130
        nbits = Enc.log2_floor_non_zero(insertlen - 2) - 1
        ((nbits << 1) + ((insertlen - 2) >> nbits) + 2).to_u16
      elsif insertlen < 2114
        (Enc.log2_floor_non_zero(insertlen - 66) + 10).to_u16
      elsif insertlen < 6210
        21_u16
      elsif insertlen < 22594
        22_u16
      else
        23_u16
      end
    end

    def self.copy_length_code(copylen : Int32) : UInt16
      if copylen < 10
        (copylen - 2).to_u16
      elsif copylen < 134
        nbits = Enc.log2_floor_non_zero(copylen - 6) - 1
        ((nbits << 1) + ((copylen - 6) >> nbits) + 4).to_u16
      elsif copylen < 2118
        (Enc.log2_floor_non_zero(copylen - 70) + 12).to_u16
      else
        23_u16
      end
    end

    def self.combine_length_codes(inscode : UInt16, copycode : UInt16,
                                  use_last_distance : Bool) : UInt16
      bits64 = (copycode & 0x7) | ((inscode & 0x7) << 3)
      if use_last_distance && inscode < 8 && copycode < 16
        copycode < 8 ? bits64 : (bits64 | 64)
      else
        offset = 2 * ((copycode >> 3) + 3 * (inscode >> 3))
        offset = (offset << 5) + 0x40 + ((0x520D40 >> offset) & 0xC0)
        (offset | bits64).to_u16
      end
    end

    def self.length_code(insertlen : Int32, copylen : Int32,
                         use_last_distance : Bool) : UInt16
      combine_length_codes(insert_length_code(insertlen),
                           copy_length_code(copylen), use_last_distance)
    end

    def self.insert_base(inscode : Int32) : UInt32
      K_BROTLI_INS_BASE.unsafe_fetch(inscode)
    end

    def self.insert_extra(inscode : Int32) : UInt32
      K_BROTLI_INS_EXTRA.unsafe_fetch(inscode)
    end

    def self.copy_base(copycode : Int32) : UInt32
      K_BROTLI_COPY_BASE.unsafe_fetch(copycode)
    end

    def self.copy_extra(copycode : Int32) : UInt32
      K_BROTLI_COPY_EXTRA.unsafe_fetch(copycode)
    end

    # prefix.h: PrefixEncodeCopyDistance. distance_code is an intermediate
    # code: a short code (0..15), a direct code, or distance + 15.
    # Returns {prefix_code, extra_bits}; prefix packs the number of extra
    # bits into the high 6 bits (<< 10).
    def self.prefix_encode_copy_distance(distance_code : UInt64,
                                         num_direct_codes : UInt32,
                                         postfix_bits : UInt32) : {UInt16, UInt32}
      if distance_code < Brotli::NUM_DISTANCE_SHORT_CODES + num_direct_codes
        return {distance_code.to_u16, 0_u32}
      end
      dist = (1_u64 << (postfix_bits + 2)) +
             (distance_code - Brotli::NUM_DISTANCE_SHORT_CODES - num_direct_codes)
      bucket = Enc.log2_floor_non_zero(dist) - 1
      postfix_mask = (1_u64 << postfix_bits) &- 1
      postfix = dist & postfix_mask
      prefix = (dist >> bucket) & 1
      offset = (2_u64 + prefix) << bucket
      nbits = bucket - postfix_bits
      code = (nbits << 10) |
             (Brotli::NUM_DISTANCE_SHORT_CODES + num_direct_codes +
              ((2 * (nbits - 1) + prefix) << postfix_bits) + postfix)
      {code.to_u16, ((dist - offset) >> postfix_bits).to_u32!}
    end

    # A sequence of literals followed by a backward-reference copy.
    struct Command
      property insert_len : UInt32
      # copy_len in low 25 bits, copy_code - copy_len in high 7 bits.
      property copy_len : UInt32
      property dist_extra : UInt32
      property cmd_prefix : UInt16
      # distance code in low 10 bits, number of extra bits in high 6 bits.
      property dist_prefix : UInt16

      # InitCommand: distance_code is e.g. 0 for same-as-last short code,
      # or 16 for offset 1 (intermediate code). The distance prefix/extra
      # are stored as if npostfix and ndirect were 0-compatible; they are
      # recomputed after clustering if needed (RecomputeDistancePrefixes).
      def initialize(@insertlen : Int32, copylen : Int32,
                     copylen_code_delta : Int32, distance_code : UInt64,
                     dist : DistanceParams)
        delta = copylen_code_delta.to_u8!
        @insert_len = insertlen.to_u32!
        @copy_len = copylen.to_u32! | (delta.to_u32 << 25)
        code, extra = Enc.prefix_encode_copy_distance(
          distance_code, dist.num_direct_distance_codes,
          dist.distance_postfix_bits)
        @dist_prefix = code
        @dist_extra = extra
        @cmd_prefix = Enc.length_code(
          insertlen, copylen + copylen_code_delta,
          (@dist_prefix & 0x3FF) == 0)
      end

      # InitInsertCommand: insert-only command (last tail of a metablock).
      # Sets dist_prefix = NUM_DISTANCE_SHORT_CODES directly (16 is NOT
      # re-encoded through prefix_encode_copy_distance — at ndirect = 0 it
      # would fall into the regular branch and become (1 << 10) | 16).
      def self.insert(insertlen : Int32) : Command
        cmd = Command.allocate
        cmd.insert_len = insertlen.to_u32!
        cmd.copy_len = 4_u32 << 25
        cmd.dist_extra = 0_u32
        cmd.dist_prefix = Brotli::NUM_DISTANCE_SHORT_CODES.to_u16
        cmd.cmd_prefix = Enc.length_code(insertlen, 4, false)
        cmd
      end

      # CommandRestoreDistanceCode: intermediate distance code back from
      # the stored prefix/extra with the given distance params.
      def restore_distance_code(dist : DistanceParams) : UInt32
        dcode = (@dist_prefix & 0x3FF).to_u32
        if dcode < Brotli::NUM_DISTANCE_SHORT_CODES + dist.num_direct_distance_codes
          return dcode
        end
        nbits = @dist_prefix >> 10
        extra = @dist_extra
        postfix_mask = (1_u32 << dist.distance_postfix_bits) &- 1
        bucket_base = dcode &- dist.num_direct_distance_codes &-
                      Brotli::NUM_DISTANCE_SHORT_CODES.to_u32!
        hcode = bucket_base >> dist.distance_postfix_bits
        lcode = bucket_base & postfix_mask
        offset = ((2 + (hcode & 1)) << nbits) &- 4
        (((offset &+ extra) << dist.distance_postfix_bits) &+ lcode &+
          dist.num_direct_distance_codes &+
          Brotli::NUM_DISTANCE_SHORT_CODES.to_u32!).to_u32!
      end

      def distance_context : UInt32
        r = @cmd_prefix >> 6
        c = @cmd_prefix & 7
        return c.to_u32 if (r == 0 || r == 2 || r == 4 || r == 7) && c <= 2
        3_u32
      end

      def copy_len : UInt32
        @copy_len & 0x1FFFFFF
      end

      def copy_len_code : UInt32
        modifier = @copy_len >> 25
        delta = (modifier | ((modifier & 0x40) << 1)).to_u8!.to_i8!
        ((@copy_len & 0x1FFFFFF).to_i32 &+ delta.to_i32).to_u32!
      end
    end
  end
end
