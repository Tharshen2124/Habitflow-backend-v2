class CreatePayments < ActiveRecord::Migration[8.1]
  def change
    create_table :payments, id: false do |t|
      t.primary_key :payment_id
      t.bigint :user_id, null: false

      # The idempotency key. Stripe delivers a webhook at least once and replays anything that does
      # not answer 2xx, so "record this payment" has to be safe to run twice -- and the unique index
      # below is what makes that true when two deliveries race, exactly as weekly_summaries' is.
      t.string :stripe_invoice_id, null: false

      # Minor units, as Stripe reports them: RM 25.00 is 2500. Kept as an integer for the reason
      # money always is -- a float cannot hold 0.1 -- and the currency travels beside it rather than
      # being assumed, since the amount alone does not say what was charged.
      t.integer :amount_cents, null: false
      t.string :currency, null: false

      # "paid" or "failed". A failed charge is recorded rather than dropped: it is the earliest
      # signal of a subscription about to lapse, which is exactly what admin analytics wants to see.
      t.string :status, null: false

      # Null on a failure -- there is no moment at which it was paid.
      t.datetime :paid_at

      # No updated_at: a payment is a fact about a moment and is never edited, the same reason
      # weekly_summaries and goal_carryovers carry only created_at.
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :payments, :stripe_invoice_id, unique: true
    # Admin analytics reads this table one user at a time, and a user's own history is the only
    # other way in.
    add_index :payments, :user_id
    add_foreign_key :payments, :users, column: :user_id, primary_key: :user_id
  end
end
