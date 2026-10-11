# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)
desc "Fetch checksum-pinned reference data into ignored tmp/"
task :fixtures do
  require_relative "script/update_registry"
  RFCFixtures.prepare
  IODEFRegistry.audit(File.join(RFCFixtures::ROOT, "sources/iodef2.xml"))
end
task spec: :fixtures
task test: :spec
task default: :spec
