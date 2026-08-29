# Writes what Stripe says about a subscription onto the user.
#
# Shared by the webhook and by the redirect confirm, which is the whole point: both answer "what
# does this subscription mean for this account?", and two implementations of that would drift the
# first time a status was added. The same reason ArchiveGoal is shared by /roles and onboarding's
# re-submit.
#
# Safe to run repeatedly. Every field is copied from the event rather than derived from what is
# already stored, so a webhook delivered twice, or delivered after the confirm has already run,
# writes the same values a second time.
class ApplyStripeSubscription
  def self.call(user:, subscription:)
    user.update!(
      stripe_subscription_id: subscription.id,
      subscription_status: subscription.status,
      subscription_period_end: period_end(subscription)
    )
    user
  end

  # current_period_end was moved off Subscription and onto its items in the 2025 API versions, so it
  # is read from the first item rather than the subscription. One item, because this app sells one
  # price -- and `&.` rather than `[0]` because a deleted subscription can arrive with none.
  def self.period_end(subscription)
    seconds = subscription.items&.data&.first&.current_period_end
    seconds && Time.zone.at(seconds)
  end

  private_class_method :period_end
end
