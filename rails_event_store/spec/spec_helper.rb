if ENV['CODECLIMATE_REPO_TOKEN']
  require 'codeclimate-test-reporter'
  CodeClimate::TestReporter.start
end

$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'rails_event_store'
require 'in_memory/event_in_memory_repository'
require 'matchers/event_store_matcher'
require 'example_invoicing_app'