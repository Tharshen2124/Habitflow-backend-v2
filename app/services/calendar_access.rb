# Resolves a live Google access token for a user, refreshing it when it has expired.
#
# Access tokens last an hour; a week's plan is synced days or weeks after the calendar was
# connected. Without this the feature would work once and then quietly stop, which is exactly what
# the unused google_token_expires_at column has been waiting for -- it is written by the sign-in
# callback and read by nothing.
class CalendarAccess
  # Refresh a little early rather than exactly on the boundary: a token with four seconds left will
  # expire mid-sync, and re-running thirty writes is worse than one extra refresh.
  EXPIRY_MARGIN = 60.seconds

  CALENDAR_NAME = "HabitFlow".freeze
  CALENDAR_DESCRIPTION = "Your HabitFlow weekly plan. HabitFlow keeps this calendar in step with " \
                         "your schedule, so an event edited here is replaced the next time your " \
                         "plan changes.".freeze

  def self.token_for(user)
    return nil if user.calendar_refresh_token.blank?
    return user.calendar_access_token if fresh?(user)

    refresh(user)
  end

  def self.fresh?(user)
    user.calendar_access_token.present? &&
      user.calendar_token_expires_at.present? &&
      user.calendar_token_expires_at > EXPIRY_MARGIN.from_now
  end

  def self.refresh(user)
    tokens = GoogleOauthClient.refresh_access_token(user.calendar_refresh_token)
    return nil if tokens.nil?

    if tokens["error"].present?
      # The user revoked access from their own Google account settings. Nothing here can fix that,
      # and leaving the row connected would show /settings a connected card whose every action
      # fails. Clearing it puts them back on the Connect button, which is the actual remedy.
      Rails.logger.warn("Google refused to refresh the calendar grant for user #{user.user_id}: #{tokens['error']}")
      user.disconnect_calendar!
      return nil
    end

    user.update!(
      calendar_access_token: tokens["access_token"],
      calendar_token_expires_at: Time.current + tokens["expires_in"].to_i.seconds
    )
    user.calendar_access_token
  end

  # The calendar we write into, creating it if there isn't one. Also the recovery path for a user
  # who deleted the HabitFlow calendar in Google's own UI: every stored event id then points into a
  # calendar that no longer exists, and a stale id is worse than none -- the next sync would patch
  # an event on a dead calendar and read the 404 as "the user deleted this one event".
  def self.ensure_calendar(user, token, time_zone, recreate: false)
    return user.calendar_id if user.calendar_id.present? && !recreate

    result = GoogleCalendarClient.create_calendar(token, summary: CALENDAR_NAME,
                                                         description: CALENDAR_DESCRIPTION,
                                                         time_zone: time_zone)
    return nil unless result.ok?

    user.tasks.where.not(google_calendar_event_id: nil)
        .update_all(google_calendar_event_id: nil, sync_status: nil)
    user.update!(calendar_id: result.body["id"])
    user.calendar_id
  end

  private_class_method :fresh?, :refresh
end
