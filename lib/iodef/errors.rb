# frozen_string_literal: true

module Iodef
  Violation = Data.define(:pointer, :rule, :message)

  class Error < StandardError; end
  class ParseError < Error; end
  class ConversionError < Error; end

  class ValidationError < Error
    attr_reader :violations, :pointer

    def initialize(message = "invalid IODEF document", pointer: "", violations: [])
      @violations = violations.freeze
      @pointer = violations.first&.pointer || pointer
      super("#{message} at #{@pointer.empty? ? "/" : @pointer}")
    end
  end

  class LimitError < ValidationError; end
end
