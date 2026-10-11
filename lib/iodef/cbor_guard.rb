# frozen_string_literal: true

module Iodef
  # Validate the wire representation and resource bounds while decoding it once.
  class CBORGuard
    def initialize(bytes, limits)
      @bytes = bytes
      @limits = limits
    end

    def validate!
      BinaryCBOR.decode(@bytes, **@limits.slice(:max_input_size, :max_depth, :max_nodes, :max_collection_size, :max_binary_size),
                        max_string_size: @limits[:max_input_size], allowed_tags: [0, 2, 3, 22, 23, 32])
    rescue BinaryCBOR::LimitError => e
      raise LimitError, e.message
    rescue BinaryCBOR::UnsupportedError => e
      raise ConversionError, e.message
    rescue BinaryCBOR::Error => e
      raise ParseError, e.message
    end
  end
end
