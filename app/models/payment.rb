# One row per invoice Stripe has told us about: what was charged, in what currency, and whether it
# went through. Written only by RecordStripePayment, from a webhook.
#
# Nothing reads it yet. It exists now because a payment is only knowable at the moment Stripe says
# so -- an admin dashboard built later cannot go back and ask what was charged last March.
class Payment < ApplicationRecord
  self.primary_key = "payment_id"

  belongs_to :user, foreign_key: "user_id", primary_key: "user_id"

  PAID = "paid".freeze
  FAILED = "failed".freeze
  STATUSES = [ PAID, FAILED ].freeze

  validates :stripe_invoice_id, presence: true, uniqueness: true
  validates :amount_cents, presence: true, numericality: { only_integer: true }
  validates :currency, presence: true
  validates :status, inclusion: { in: STATUSES }
  # A paid row without the moment it was paid would leave revenue-over-time unanswerable, which is
  # the one question this table exists for. A failure has no such moment, so it is only required
  # of the status that has one.
  validates :paid_at, presence: true, if: -> { status == PAID }

  def paid? = status == PAID
end
