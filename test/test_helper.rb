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

    # Replaces one class method for the duration of a block.
    #
    # Minitest 6 dropped minitest/mock, so Object#stub no longer exists, and the only thing this
    # suite wants from it is standing in for GeminiSummaryClient so the tests never touch the
    # network. That is a dozen lines, which is a smaller commitment than webmock or a mocking gem.
    #
    # A callable `value` is called with the arguments the real method received -- which is how a
    # test asserts a method was *not* reached, or makes it raise. Anything else is returned as-is.
    def stubbing(owner, name, value)
      original = owner.method(name)
      replacement = value.respond_to?(:call) ? value : ->(*) { value }
      owner.define_singleton_method(name) { |*args, **kwargs, &block| replacement.call(*args, **kwargs, &block) }
      yield
    ensure
      owner.singleton_class.remove_method(name)
      owner.define_singleton_method(name, original)
    end

    # `stubbing` for several methods on one owner at once, so a test that stands in for a whole
    # client is not four levels of nesting deep.
    def stubbing_all(owner, stubs, &block)
      return block.call if stubs.empty?

      name, value = stubs.first
      stubbing(owner, name, value) { stubbing_all(owner, stubs.drop(1), &block) }
    end

    # Records the calls a stubbed method received, so a test can assert what a reconcile *did*
    # rather than what it returned. Returns [recorded, callable] for `stubbing`.
    def recording(returning = nil)
      calls = []
      [ calls, ->(*args, **kwargs) { calls << args; returning.respond_to?(:call) ? returning.call(*args, **kwargs) : returning } ]
    end

    # Add more helper methods to be used by all tests here...
  end
end
