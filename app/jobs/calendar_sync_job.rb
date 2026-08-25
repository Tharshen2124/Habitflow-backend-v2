# Pushes one week to Google Calendar out of band.
#
# The first job in this app. Saving a week's plan writes about thirty events, which is a few seconds
# against Google's API -- worth waiting for when the user pressed "Sync now" and is watching, but
# not something to hold the last step of the planning wizard open for. So the button syncs inline
# and every automatic sync comes through here.
#
# Development uses Rails' default :async adapter and production is already on solid_queue, so this
# needs no infrastructure in either.
class CalendarSyncJob < ApplicationJob
  queue_as :default

  # Rails 8.1 still defaults this to false, so an enqueue inside an open transaction fires
  # immediately -- and on the :async adapter the job starts on another thread and reads the
  # database before the commit. Every call site is already after its transaction; this is the
  # second line of defence.
  self.enqueue_after_transaction_commit = true

  def perform(user_id, week_start, time_zone)
    user = User.find_by(user_id: user_id)
    # Re-checked rather than trusted from enqueue time: the switch can be turned off, or the grant
    # revoked, between a plan being saved and the job running.
    return unless user&.calendar_connected? && user.calendar_sync_enabled?

    SyncWeekToCalendar.call(user: user, week_start: Date.iso8601(week_start), time_zone: time_zone)
  end
end
