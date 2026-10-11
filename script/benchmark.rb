# frozen_string_literal: true

require "objspace"
require_relative "../lib/iodef"

count = Integer(ARGV.fetch(0, "5000"))
incident = {
  "purpose" => "watch", "IncidentID" => { "id" => "benchmark", "name" => "team.example" },
  "GenerationTime" => "2026-01-01T00:00:00Z",
  "Contact" => [{ "role" => "creator", "type" => "organization", "ContactName" => ["Response team"] }],
  "Indicator" => Array.new(count) do |index|
    { "IndicatorID" => { "id" => "indicator#{index}", "name" => "team.example", "version" => "1" },
      "Observable" => { "Address" => { "category" => "ipv4-addr", "value" => "192.0.2.1" } } }
  end
}
data = { "version" => "2.0", "Incident" => [incident] }

def resident_kib
  Integer(IO.popen(["ps", "-o", "rss=", "-p", Process.pid.to_s], &:read).strip)
rescue SystemCallError, ArgumentError
  nil
end

source = JSON.generate(data)
before = resident_kib
heap_before = ObjectSpace.memsize_of_all
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
parsed = IODEF.parse(source)
raise "Round trip changed data" unless JSON.parse(parsed.to_json) == data

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
after = resident_kib
puts "#{count} indicators, #{source.bytesize} JSON bytes, #{elapsed.round(3)} s"
puts "Ruby heap #{heap_before} -> #{ObjectSpace.memsize_of_all} bytes; RSS #{before.inspect} -> #{after.inspect} KiB"
