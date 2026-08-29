require "test_helper"

class BackfillStripePaymentsTest < ActiveSupport::TestCase
  setup do
    @user = users(:subscriber)
    Payment.delete_all
  end

  # Shaped like the gem's invoice: RecordStripePayment reads id, amount_paid, amount_due, currency
  # and status_transitions.paid_at off it, so a Struct standing in for one has to carry all five.
  def invoice(id:, status: "paid", amount: 2500, paid_at: 3.days.ago.to_i)
    Struct.new(:id, :status, :amount_paid, :amount_due, :currency, :status_transitions, keyword_init: true).new(
      id: id, status: status, amount_paid: amount, amount_due: amount, currency: "myr",
      status_transitions: Struct.new(:paid_at, keyword_init: true).new(paid_at: paid_at)
    )
  end

  def listing(invoices)
    ->(_customer_id) { StripeClient::Result.new(value: invoices, error: nil) }
  end

  def backfill(invoices, &block)
    stubbing(StripeClient, :list_invoices, listing(invoices)) do
      BackfillStripePayments.call(users: User.where(user_id: @user.user_id))
    end.tap { |result| block&.call(result) }
  end

  test "records a paid invoice as a payment" do
    result = backfill([ invoice(id: "in_paid") ])

    assert_equal 1, result.recorded
    payment = Payment.find_by(stripe_invoice_id: "in_paid")
    assert_equal Payment::PAID, payment.status
    assert_equal 2500, payment.amount_cents
    assert_equal @user.user_id, payment.user_id
  end

  # Stripe's own timestamp, not the moment the backfill ran — otherwise a catch-up would file every
  # invoice ever taken under today, and the revenue trend would be one enormous bar.
  test "files a payment under the moment Stripe says it was paid" do
    paid_at = 200.days.ago.to_i
    backfill([ invoice(id: "in_old", paid_at: paid_at) ])

    assert_equal paid_at, Payment.find_by(stripe_invoice_id: "in_old").paid_at.to_i
  end

  test "records an uncollectible invoice as a failure" do
    backfill([ invoice(id: "in_gone", status: "uncollectible") ])

    assert_equal Payment::FAILED, Payment.find_by(stripe_invoice_id: "in_gone").status
  end

  # An open invoice is still being retried and a draft has not been issued; recording either as
  # failed would report a charge that may yet succeed. A void one was cancelled and never was money.
  test "ignores invoices that have not settled" do
    result = backfill(%w[draft open void].map { |s| invoice(id: "in_#{s}", status: s) })

    assert_equal 0, result.recorded
    assert_equal 3, result.ignored
    assert_equal 0, Payment.count
  end

  # The whole point of running it after the fact: it must be re-runnable without doubling revenue.
  test "running it twice records nothing the second time" do
    invoices = [ invoice(id: "in_a"), invoice(id: "in_b") ]

    first = backfill(invoices)
    second = backfill(invoices)

    assert_equal 2, first.recorded
    assert_equal 0, second.recorded
    assert_equal 2, second.already_held
    assert_equal 2, Payment.count
  end

  # A row the webhook already wrote is left exactly as it is — the two must not be able to disagree
  # about the same invoice.
  test "leaves a payment the webhook already recorded alone" do
    RecordStripePayment.call(user: @user, invoice: invoice(id: "in_hook"), status: Payment::PAID)
    existing = Payment.find_by(stripe_invoice_id: "in_hook")

    result = backfill([ invoice(id: "in_hook", amount: 9999) ])

    assert_equal 0, result.recorded
    assert_equal 2500, existing.reload.amount_cents
  end

  # An account Stripe cannot be asked about is named rather than silently skipped, and it must not
  # take the rest of the run down with it.
  test "reports an account it could not reach instead of raising" do
    unreachable = ->(_id) { StripeClient::Result.new(value: nil, error: :unavailable) }

    result = stubbing(StripeClient, :list_invoices, unreachable) do
      BackfillStripePayments.call(users: User.where(user_id: @user.user_id))
    end

    assert_equal [ @user.email ], result.unreachable
    assert_equal 0, result.recorded
  end

  # Accounts that never checked out have no customer to ask about, so the default scope skips them.
  test "asks only about accounts with a Stripe customer" do
    asked, recorder = recording(StripeClient::Result.new(value: [], error: nil))

    stubbing(StripeClient, :list_invoices, recorder) { BackfillStripePayments.call }

    assert_equal User.where.not(stripe_customer_id: nil).count, asked.length
    assert_includes asked.flatten, @user.stripe_customer_id
  end
end
