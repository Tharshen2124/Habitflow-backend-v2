# Records one invoice as a payments row.
#
# Written to be run twice. Stripe delivers a webhook at least once and replays anything that does
# not answer 2xx, so this either creates the row or finds the one an earlier delivery already made;
# the unique index on stripe_invoice_id is what settles it when two deliveries race, and the rescue
# is what turns losing that race into a no-op rather than a 500 that asks Stripe to try again.
class RecordStripePayment
  def self.call(user:, invoice:, status:)
    Payment.create!(
      user: user,
      stripe_invoice_id: invoice.id,
      amount_cents: amount_cents(invoice, status),
      currency: invoice.currency,
      status: status,
      paid_at: paid_at(invoice, status)
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Already recorded. A payment is a fact about a moment and is never edited, so there is nothing
    # to update and the second delivery has nothing left to do.
    Payment.find_by(stripe_invoice_id: invoice.id)
  end

  # amount_paid is 0 on a failure, which would record a real charge as costing nothing. What was
  # *attempted* is the useful figure there, and it is the one a later dashboard would sum.
  def self.amount_cents(invoice, status)
    status == Payment::PAID ? invoice.amount_paid : invoice.amount_due
  end

  # Stripe's own timestamp for when the invoice moved to paid, rather than when we heard about it --
  # a webhook retried for an hour would otherwise record the payment an hour late.
  def self.paid_at(invoice, status)
    return nil unless status == Payment::PAID

    seconds = invoice.status_transitions&.paid_at
    seconds ? Time.zone.at(seconds) : Time.current
  end

  private_class_method :amount_cents, :paid_at
end
