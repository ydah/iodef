# frozen_string_literal: true

require "json"
require "yaml"
require "date"
require "uri"
require_relative "iodef/version"
require_relative "iodef/errors"
require_relative "iodef/types"
require_relative "iodef/validator"
require_relative "iodef/model"

IODEF = Iodef unless defined?(IODEF)

module Iodef
  class << self
    # Reads one JSON IODEF document; unknown properties survive round trips.
    def parse(source, strict: true, validate: true, **limits)
      options = self.limits(limits)
      raise ParseError, "JSON input must be a String" unless source.is_a?(String)
      raise LimitError, "input exceeds max_input_size" if source.bytesize > options[:max_input_size]

      value = JSON.parse(source, allow_duplicate_key: false, max_nesting: options[:max_depth])
      Document.new(value, strict: strict && validate, **options)
    rescue JSON::NestingError
      raise LimitError, "input exceeds max_depth"
    rescue JSON::ParserError, EncodingError
      raise ParseError, "invalid JSON input"
    end

    # Returns all bounded diagnostics, without embedding confidential input values.
    def validate(source, **limits)
      return parse(source, strict: false, **limits).warnings if source.is_a?(String)

      Validator.new(**limits).validate(source.is_a?(Model) ? source.to_h : source)
    rescue ParseError => e
      [Violation.new(pointer: "", rule: "json", message: e.message)]
    end
  end
end
