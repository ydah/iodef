# frozen_string_literal: true

if ENV["COVERAGE"] == "1"
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    add_filter "/script/"
    minimum_coverage 90
  end
end
require "iodef"

module Examples
  def minimal
    { "version" => "2.0", "Incident" => [{ "purpose" => "reporting", "IncidentID" => { "id" => "case-1", "name" => "team.example" },
                                           "GenerationTime" => "2026-01-01T00:00:00Z",
                                           "Contact" => [{ "role" => "creator", "type" => "organization", "ContactName" => ["Response team"] }] }] }
  end
end
RSpec.configure { |config| config.include Examples }
