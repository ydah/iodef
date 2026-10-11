# frozen_string_literal: true

require "iodef"
require_relative "binary_cbor"
require_relative "cbor_guard"

module Iodef
  module CBORCodec
    module_function

    def encode(value, type = "Document")
      return value.map { |item| encode(item, type.delete_suffix("[]")) } if type.end_with?("[]")

      if value.is_a?(Hash)
        fields = SCHEMA.fetch(type == "mlstring" ? "MLString" : type, {}).fetch("fields", {})
        return value.to_h do |key, item|
          descriptor = fields.fetch(key, "any").delete_suffix("!")
          descriptor = content_type(value) if key == "value" && %w[Extension SoftwareReference].include?(type)
          [MAPKEYS.fetch(key, key), encode(item, descriptor)]
        end
      end
      return value.map { |item| encode(item, "any") } if value.is_a?(Array)
      return BinaryCBOR::Tagged.new(22, value.unpack1("m0").b) if type == "binary"
      return BinaryCBOR::Tagged.new(23, [value].pack("H*").b) if type == "hex"
      return BinaryCBOR::Tagged.new(0, value) if type == "datetime"
      return BinaryCBOR::Tagged.new(32, value) if type == "uri"

      if %w[number positive].include?(type)
        rounded = [value].pack("g").unpack1("g")
        raise ConversionError, "IODEF CBOR real values must be exactly representable as float32" unless rounded.finite? && rounded == value

        return BinaryCBOR::Float32.new(rounded)
      end
      value
    end

    def decode(value, type = "Document", path = "")
      if type.end_with?("[]") && value.is_a?(Array)
        return value.each_with_index.map { |item, index| decode(item, type.delete_suffix("[]"), Iodef.pointer(path, index)) }
      end
      return decode_object(value, type, path) if value.is_a?(Hash)
      return value.each_with_index.map { |item, index| decode(item, "any", Iodef.pointer(path, index)) } if value.is_a?(Array)

      if value.is_a?(BinaryCBOR::Tagged) && [2, 3].include?(value.tag)
        raise ConversionError, "bignum tag requires a byte string at #{path}" unless value.value.is_a?(String) && value.value.encoding == Encoding::BINARY

        magnitude = value.value.empty? ? 0 : value.value.unpack1("H*").to_i(16)
        value = value.tag == 3 ? -1 - magnitude : magnitude
      end
      case type
      when "binary" then decode_tag(value, 22, path) { |bytes| [bytes].pack("m0") }
      when "hex" then decode_tag(value, 23, path) { |bytes| bytes.unpack1("H*").upcase }
      when "datetime" then decode_tag(value, 0, path) { |text| text }
      when "uri" then decode_tag(value, 32, path) { |text| text }
      else
        if value.is_a?(BinaryCBOR::Tagged) || value.is_a?(BinaryCBOR::Simple) || (value.is_a?(String) && value.encoding == Encoding::BINARY)
          raise ConversionError, "CBOR value has no unambiguous JSON representation at #{path}"
        end

        value
      end
    end

    def decode_object(value, type, path)
      fields = SCHEMA.fetch(type == "mlstring" ? "MLString" : type, {}).fetch("fields", {})
      named = value.each_with_object({}) do |(key, item), result|
        key = KEYNAMES.fetch(key) { raise ConversionError, "unassigned CBOR map key at #{path}" } if key.is_a?(Integer)
        raise ConversionError, "CBOR map key must be a text string or assigned integer at #{path}" unless key.is_a?(String) && key.encoding != Encoding::BINARY
        raise ParseError, "colliding CBOR map keys at #{path}" if result.key?(key)

        result[key] = item
      end
      named.to_h do |key, item|
        descriptor = fields.fetch(key, "any").delete_suffix("!")
        descriptor = content_type(named) if key == "value" && %w[Extension SoftwareReference].include?(type)
        [key, decode(item, descriptor, Iodef.pointer(path, key))]
      end
    end

    def content_type(value)
      case value["dtype"]
      when "byte", "file" then "binary"
      when "bytes", "frame", "packet", "ipv4-packet", "ipv6-packet" then "hex"
      else "string"
      end
    end

    def decode_tag(value, tag, path)
      binary = [22, 23].include?(tag)
      return yield(value) if value.is_a?(String) && (value.encoding == Encoding::BINARY) == binary

      valid = value.is_a?(BinaryCBOR::Tagged) && value.tag == tag && value.value.is_a?(String)
      valid &&= (value.value.encoding == Encoding::BINARY) == [22, 23].include?(tag)
      raise ConversionError, "expected CBOR tag #{tag} at #{path}" unless valid

      yield value.value
    end
  end

  class << self
    def parse_cbor(bytes, strict: true, validate: true, **limits)
      options = self.limits(limits)
      raise ParseError, "CBOR input must be a String" unless bytes.is_a?(String)
      raise LimitError, "input exceeds max_input_size" if bytes.bytesize > options[:max_input_size]

      data = CBORCodec.decode(CBORGuard.new(bytes, options).validate!)
      Document.new(data, strict: strict && validate, **options)
    end
  end

  class Document
    def to_cbor
      validate!
      bytes = BinaryCBOR.encode(CBORCodec.encode(to_h), max_output_size: limits[:max_input_size])
      raise LimitError, "output exceeds max_input_size" if bytes.bytesize > limits[:max_input_size]

      bytes
    rescue BinaryCBOR::LimitError => e
      raise LimitError, e.message
    rescue BinaryCBOR::Error => e
      raise ConversionError, e.message
    end
  end
end
