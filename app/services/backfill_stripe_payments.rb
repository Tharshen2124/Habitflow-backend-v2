# Records the invoices Stripe already holds for accounts that were charged while no webhook was
# reaching this app.
#
# It exists because of a gap that is deliberate everywhere else. `POST /subscription/confirm` writes
# subscription state from the browser redirect so a user back from Checkout is not shown "Free"
# while the webhook is in flight -- and it deliberately does **not** write a payment, because a
# payment is a fact Stripe reports, not something to infer from a redirect. So a machine where
# `stripe listen` was never running ends up with premium accounts and no revenue at all: the
# subscription half of the truth arrived by the road that always works, and the money half by the
# road that was not connected.
#
# This is the catch-up and nothing more. It hands each invoice to the same `RecordStripePayment` the
# webhook calls, so a row written here is indistinguishable from one the webhook would have written,
# and it is safe to run as often as you like -- `payments.stripe_invoice_id` is unique, and that
# service already treats losing that race as a no-op.
#
# It is not a substitute for the webhook. Run `stripe listen --forward-to
# localhost:3000/subscription/webhook` and new payments record themselves.
class BackfillStripePayments
  Result = Data.define(:recorded, :already_held, :ignored, :unreachable)

  # Stripe's invoice statuses, mapped to the two this app stores.
  #
  # Only the two settled ones are recorded. `draft` and `open` have not resolved -- an open invoice
  # is still being retried, and writing it as failed would report a charge that may yet succeed --
  # and `void` was cancelled, so it was never money. The webhook draws the same line by only
  # listening for `invoice.paid` and `invoice.payment_failed`.
  STATUSES = {
    "paid" => Payment::PAID,
    "uncollectible" => Payment::FAILED
  }.freeze

  def self.call(users: User.where.not(stripe_customer_id: nil))
    recorded = 0
    already_held = 0
    ignored = 0
    unreachable = []

    users.find_each do |user|
      invoices = StripeClient.list_invoices(user.stripe_customer_id)
      next unreachable << user.email unless invoices.ok?

      invoices.value.each do |invoice|
        status = STATUSES[invoice.status]
        next ignored += 1 if status.nil?

        # Asked before the write rather than inferred from what comes back: RecordStripePayment
        # returns the existing row on a repeat, which is correct behaviour and indistinguishable
        # from a fresh insert. The count is only for the operator reading the output.
        held = Payment.exists?(stripe_invoice_id: invoice.id)
        RecordStripePayment.call(user: user, invoice: invoice, status: status)
        held ? already_held += 1 : recorded += 1
      end
    end

    Result.new(recorded: recorded, already_held: already_held, ignored: ignored, unreachable: unreachable)
  end
end
