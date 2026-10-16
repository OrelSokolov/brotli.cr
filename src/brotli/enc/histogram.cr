# Port of c/enc/histogram.{c,h} + histogram_inc.h. Upstream: 42a2ed4.
#
# C instantiates the histogram template over literal/command/distance
# alphabets; here one monomorphic class carries the alphabet size, which
# is all the cluster/splitter machinery ever needs.

module Brotli
  module Enc
    NUM_HISTOGRAM_DISTANCE_SYMBOLS = 544

    # histogram_inc.h — a simple container for histograms of data in blocks.
    class Histogram
      getter data : Slice(UInt32)
      getter data_size : Int32
      property total_count : UInt32
      property bit_cost : Float64

      def initialize(@data_size : Int32)
        @data = Slice(UInt32).new(@data_size)
        @total_count = 0_u32
        @bit_cost = Float64::INFINITY # HUGE_VAL
      end

      def initialize(@data_size : Int32, @data : Slice(UInt32),
                     @total_count : UInt32, @bit_cost : Float64)
      end

      def self.literal : Histogram
        new(Brotli::NUM_LITERAL_SYMBOLS)
      end

      def self.command : Histogram
        new(Brotli::NUM_COMMAND_SYMBOLS)
      end

      def self.distance : Histogram
        new(NUM_HISTOGRAM_DISTANCE_SYMBOLS)
      end

      def copy_from(other : Histogram) : Nil
        @data.copy_from(other.data)
        @total_count = other.total_count
        @bit_cost = other.bit_cost
      end

      # HistogramClear.
      def clear : Nil
        @data.fill(0_u32)
        @total_count = 0_u32
        @bit_cost = Float64::INFINITY
      end

      def add(val : Int) : Nil
        @data[val] &+= 1
        @total_count &+= 1
      end

      # HistogramAddHistogram.
      def add_histogram(other : Histogram) : Nil
        @total_count &+= other.total_count
        i = 0
        while i < @data_size
          @data.to_unsafe[i] &+= other.data.unsafe_fetch(i)
          i += 1
        end
      end
    end

    # histogram.c:20 — walks a BlockSplit assigning a type per consumed
    # symbol (literal / command / distance index).
    class BlockSplitIterator
      getter split : BlockSplit
      property idx : Int32
      property type : Int32
      property length : Int32

      def initialize(@split : BlockSplit)
        @idx = 0
        @type = 0
        @length = @split.lengths.empty? ? 0 : @split.lengths[0].to_i32
      end

      def next : Nil
        if @length == 0
          @idx += 1
          @type = @split.types[@idx].to_i32
          @length = @split.lengths[@idx].to_i32
        end
        @length -= 1
      end
    end

    # histogram.c:44 — per-context histograms of literals, commands and
    # distance codes over the command stream of one metablock.
    def self.build_histograms_with_context(
        commands : Array(Command), literal_split : BlockSplit,
        insert_and_copy_split : BlockSplit, dist_split : BlockSplit,
        ringbuffer : Bytes, start_pos : Int32, mask : Int32,
        prev_byte : UInt8, prev_byte2 : UInt8,
        context_modes : Slice(Int32)?,
        literal_histograms : Array(Histogram),
        insert_and_copy_histograms : Array(Histogram),
        copy_dist_histograms : Array(Histogram)) : Nil
      pos = start_pos
      literal_it = BlockSplitIterator.new(literal_split)
      insert_and_copy_it = BlockSplitIterator.new(insert_and_copy_split)
      dist_it = BlockSplitIterator.new(dist_split)

      commands.each do |cmd|
        insert_and_copy_it.next
        insert_and_copy_histograms[insert_and_copy_it.type]
          .add(cmd.cmd_prefix)
        j = cmd.insert_len
        while j != 0
          literal_it.next
          context = literal_it.type
          if context_modes
            mode = context_modes.not_nil!.unsafe_fetch(context) & 3
            ctx = CONTEXT_LOOKUP.unsafe_fetch((mode << 9) | prev_byte).to_i32 |
                  CONTEXT_LOOKUP.unsafe_fetch((mode << 9) | 256 | prev_byte2).to_i32
            context = (context << Brotli::LITERAL_CONTEXT_BITS) + ctx
          end
          literal_histograms[context].add(ringbuffer.unsafe_fetch(pos & mask))
          prev_byte2 = prev_byte
          prev_byte = ringbuffer.unsafe_fetch(pos & mask)
          pos += 1
          j -= 1
        end
        pos += cmd.copy_len
        if cmd.copy_len != 0
          prev_byte2 = ringbuffer.unsafe_fetch((pos - 2) & mask)
          prev_byte = ringbuffer.unsafe_fetch((pos - 1) & mask)
          if cmd.cmd_prefix >= 128
            dist_it.next
            context = (dist_it.type << Brotli::DISTANCE_CONTEXT_BITS) +
                      cmd.distance_context
            copy_dist_histograms[context].add(cmd.dist_prefix & 0x3FF)
          end
        end
      end
    end
  end
end
