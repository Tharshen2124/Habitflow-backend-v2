class AddStripeToUsers < ActiveRecord::Migration[8.1]
  def change
    # The paid tier is one-per-user standing state, so it sits on the user for the same reason the
    # Google Calendar grant does rather than getting a table of its own. What a user has *paid* is a
    # history and does get one -- see CreatePayments.
    add_column :users, :stripe_customer_id, :string
    add_column :users, :stripe_subscription_id, :string

    # Stripe's own vocabulary, stored verbatim: "active", "trialing", "past_due", "canceled",
    # "incomplete", "unpaid". Deliberately not mapped onto a local enum -- a status Stripe adds
    # later would otherwise fall through a `case` with no `else` and be recorded as a lie.
    add_column :users, :subscription_status, :string

    # When the period already paid for runs out. Read off the subscription's *item* rather than the
    # subscription: current_period_end was moved to SubscriptionItem in the 2025 API versions, and
    # this app is pinned well past that.
    add_column :users, :subscription_period_end, :datetime

    # Both are Stripe's ids, so one row each. The customer index is also what makes a webhook cheap:
    # every event but the first arrives naming a customer and nothing else we know.
    add_index :users, :stripe_customer_id, unique: true
    add_index :users, :stripe_subscription_id, unique: true
  end
end
