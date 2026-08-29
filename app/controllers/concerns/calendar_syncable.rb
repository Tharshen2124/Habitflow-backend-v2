# The auto-sync hook. Any controller action that changes what an event would say calls
# `sync_calendar_later` after its write succeeds.
#
# It is a no-op unless the user is on the paid tier, has connected a calendar and left the switch
# on, so the cost to a user who has never touched the feature is one boolean.
#
# The premium check is here rather than on each of the nine actions that call this, because this is
# the only place in the app that enqueues a CalendarSyncJob -- gating it once gates every write that
# could reach Google. Pushing a schedule *manually* stays free: calendar#sync runs inline and
# deliberately does not come through here, which is the whole distinction the pricing page draws
# between "Push your schedule to Google Calendar" and "Sync calendar edits automatically".
module CalendarSyncable
  extend ActiveSupport::Concern

  private

  # Syncs the named week and every week after it. A week ahead is included because a rename reaches
  # further than the week it was made in: a role's name is in the description of every event of
  # every task under it, in this week and in next week's plan if one exists. Weeks already gone are
  # left alone -- they are read as they were recorded, the line /history and /analytics also draw.
  def sync_calendar_later
    return unless current_user.premium?
    return unless current_user.calendar_connected? && current_user.calendar_sync_enabled?

    zone = current_time_zone
    return if zone.nil? || week_start.nil?

    current_user.weekly_plans.where(start_date: week_start..).pluck(:start_date).each do |start_date|
      CalendarSyncJob.perform_later(current_user.user_id, start_date.iso8601, zone)
    end
  end

  # The browser's IANA zone, sent as a header on every request by next-app's api.ts.
  #
  # A Google event needs a zone -- an RFC3339 dateTime without one is rejected -- and the server
  # deliberately stores none, for the same reason it never derives "the current week" itself. So the
  # client supplies it per request, exactly as it supplies week_start. A request without a usable
  # one skips the sync rather than guessing: a guessed zone silently files a whole week at the wrong
  # hour, which is worse than not filing it.
  def current_time_zone
    raw = request.headers["X-Time-Zone"].presence
    return nil if raw.nil?

    TZInfo::Timezone.get(raw)
    raw
  rescue TZInfo::InvalidTimezoneIdentifier
    nil
  end
end
