# frozen_string_literal: true

require_relative "../iodef"
require "rexml/parsers/pullparser"
require_relative "xml/tree"
require_relative "xml/codec"

module Iodef
  class << self
    def parse_xml(source, strict: true, validate: true, **limits)
      options = self.limits(limits)
      root = XMLTree.new(options).parse(source)
      data = XMLCodec.new(options).decode(root)
      Document.new(data, strict: strict && validate, **options)
    end
  end

  class Document
    def to_xml
      validate!
      XMLCodec.new(limits).encode(to_h)
    end
  end
end
