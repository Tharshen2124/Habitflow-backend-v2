require "test_helper"

class PaymentTest < ActiveSupport::TestCase
  setup { @user = users(:subscriber) }

  def paid(attrs = {})
    Payment.new({
      user: @user, stripe_invoice_id: "in_#{SecureRandom.hex(4)}", amount_cents: 2500,
      currency: "myr", status: Payment::PAID, paid_at: Time.current
    }.merge(attrs))
  end

  test "a paid invoice is valid" do
    assert paid.valid?
  end

  # The unique index is what makes a replayed webhook safe; this is the rule it enforces stated in
  # the model, so a second row is refused before it reaches the database.
  test "the same invoice cannot be recorded twice" do
    paid(stripe_invoice_id: "in_dup").save!
    assert_not paid(stripe_invoice_id: "in_dup").valid?
  end

  test "a status outside paid or failed is refused" do
    assert_not paid(status: "refunded").valid?
  end

  # Revenue over time is the one question this table exists to answer, and a paid row with no moment
  # it was paid cannot contribute to it.
  test "a paid row requires the moment it was paid" do
    assert_not paid(paid_at: nil).valid?
  end

  # A failure has no such moment, so it must not be asked for one.
  test "a failed row does not" do
    assert paid(status: Payment::FAILED, paid_at: nil).valid?
  end
end
