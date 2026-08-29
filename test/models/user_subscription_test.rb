require "test_helper"

# User#premium? -- the predicate the feature limits will read once they are built.
class UserSubscriptionTest < ActiveSupport::TestCase
  setup { @user = users(:subscriber) }

  test "an active subscription within its period is premium" do
    assert @user.premium?
  end

  test "a trialing subscription is premium" do
    @user.update!(subscription_status: "trialing")
    assert @user.premium?
  end

  test "an account that has never subscribed is not premium" do
    assert_not users(:one).premium?
  end

  %w[canceled past_due unpaid incomplete incomplete_expired].each do |status|
    test "a #{status} subscription is not premium" do
      @user.update!(subscription_status: status)
      assert_not @user.premium?
    end
  end

  # The half of the predicate that is not redundant with the status. Cancelling sets
  # cancel_at_period_end and leaves the status "active" until the period actually ends, so a single
  # missed webhook on that day would otherwise leave a lapsed account premium forever.
  test "an active subscription whose period has run out is not premium" do
    @user.update!(subscription_status: "active", subscription_period_end: 1.day.ago)
    assert_not @user.premium?
  end

  # A subscription Stripe has told us about but whose period we could not read is trusted on its
  # status alone -- refusing it would take Premium away from someone who is paying.
  test "an active subscription with no period recorded is premium" do
    @user.update!(subscription_status: "active", subscription_period_end: nil)
    assert @user.premium?
  end
end
