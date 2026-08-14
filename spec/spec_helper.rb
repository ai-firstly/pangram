# frozen_string_literal: true

require 'simplecov'

SimpleCov.start do
  add_filter '/spec/'
  track_files 'lib/**/*.rb'
  minimum_coverage 90
end

require 'bundler/setup'
require 'pangram'
require 'webmock/rspec'

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.example_status_persistence_file_path = '.rspec_status'

  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end
end

WebMock.disable_net_connect!
