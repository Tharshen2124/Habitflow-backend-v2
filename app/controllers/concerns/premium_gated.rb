# The paid tier's limits, in one file.
#
# `User#premium?` has existed since Stripe landed and was read by nothing; this is what reads it.
# Both halves live together because they describe the same tier: refusing a feature outright and
# handing back only part of one are the same decision made at different granularities, and split
# across two files the "3" below would eventually disagree with the copy on the pricing page.
#
# Include it *after* `Authenticatable` -- it reads `current_user`, which that concern sets. Never on
# SubscriptionsController: `checkout` is precisely the path an account takes while not yet premium.
module PremiumGated
  extend ActiveSupport::Concern

  # How many finished weeks a free account may read back through. Mirrored on the client by
  # FREE_TIER_LIMITS.historyWeeks in next-app/lib/plans.ts, which is what the pricing page prints.
  FREE_HISTORY_WEEKS = 3

  private

  # 402 rather than 403. This is not an ownership failure -- the account is exactly who it says it
  # is, and the one 403 in this app (subscriptions#confirm) means the opposite thing: a session
  # belonging to somebody else. Nothing else answers 402, so the client can branch on the status
  # instead of matching the prose, which is what lets a refusal render as an upgrade offer rather
  # than as a red sentence.
  def require_premium!
    return if current_user.premium?

    render json: { errors: [ "This is a Premium feature" ] }, status: :payment_required
  end

  # The oldest Monday a free account may read.
  #
  # Anchored on the server's own date, which everywhere else in this app is the thing it refuses to
  # do -- it stores no timezone, so it never derives "the current week". The difference here is that
  # a paywall cannot take its boundary from the client: `from`/`to` arrive in the request, and a
  # free account that named its own cut-off could walk backwards three weeks at a time through the
  # whole of its history.
  #
  # So it uses the same backstop EveningReflectionsController#week_has_closed? does, a day of slack
  # against UTC, and the slack runs in the user's favour: a boundary case is handed one week too
  # many rather than refused one it should have had. At worst someone at UTC+14 sees a fourth week
  # for a few hours, which costs nothing.
  def free_history_floor
    (Date.current - 1).beginning_of_week(:monday) - (FREE_HISTORY_WEEKS * 7)
  end
end
