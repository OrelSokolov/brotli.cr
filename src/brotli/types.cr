# Small shared record types (upstream c/dec/prefix.h CmdLutElement etc.).

module Brotli
  # CmdLutElement — insert-and-copy length code lookup entry.
  struct CmdLut
    getter insert_len_extra_bits : UInt8
    getter copy_len_extra_bits : UInt8
    getter distance_code : Int8
    getter context : UInt8
    getter insert_len_offset : UInt16
    getter copy_len_offset : UInt16

    def initialize(@insert_len_extra_bits : UInt8, @copy_len_extra_bits : UInt8,
                   @distance_code : Int8, @context : UInt8,
                   @insert_len_offset : UInt16, @copy_len_offset : UInt16)
    end
  end
end
