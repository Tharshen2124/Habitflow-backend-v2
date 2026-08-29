require "test_helper"

class ApplyStripeSubscriptionTest < ActiveSupport::TestCase
  setup { @user = users(:one) }

  def subscription(status: "active", items: [ { current_period_end: 30.days.from_now.to_i } ], id: "sub_x")
    Struct.new(:id, :status, :items, keyword_init: true).new(
      id: id, status: status,
      items: Struct.new(:data, keyword_init: true).new(
        data: items.map { |i| Struct.new(:current_period_end, keyword_init: true).new(**i) }
      )
    )
  end

  test "copies the status and period end onto the user" do
    period_end = 30.days.from_now.to_i
    ApplyStripeSubscription.call(
      user: @user, subscription: subscription(items: [ { current_period_end: period_end } ])
    )

    @user.reload
    assert_equal "sub_x", @user.stripe_subscription_id
    assert_equal "active", @user.subscription_status
    assert_equal period_end, @user.subscription_period_end.to_i
  end

  # Every field is copied from the event rather than derived from what is stored, so a webhook
  # delivered twice -- or delivered after the redirect confirm already ran -- writes the same values.
  test "is safe to run twice" do
    2.times { ApplyStripeSubscription.call(user: @user, subscription: subscription) }

    assert_equal "active", @user.reload.subscription_status
  end

  # current_period_end moved off Subscription and onto its items in the 2025 API versions, and a
  # deleted subscription can arrive carrying none at all.
  test "records no period end when the subscription has no items" do
    ApplyStripeSubscription.call(user: @user, subscription: subscription(status: "canceled", items: []))

    @user.reload
    assert_equal "canceled", @user.subscription_status
    assert_nil @user.subscription_period_end
    assert_not @user.premium?
  end
end
