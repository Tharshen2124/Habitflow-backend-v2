ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # The Monday that weekly_plans(:one) and weekly_plans(:two) cover. Week-scoped endpoints take
    # a client-supplied `week_start`, so tests have to send one too.
    FIXTURE_WEEK_START = "2026-08-17".freeze

    # Add more helper methods to be used by all tests here...
  end
end
