require "test_helper"

# The only job in the app, tested for the one thing the enqueue side cannot cover: a job sits in the
# queue between being enqueued and being run, and anything it was entitled to at enqueue time can
# have been taken away by the time it runs.
class CalendarSyncJobTest < ActiveJob::TestCase
  ZONE = "Asia/Kuala_Lumpur".freeze

  def run_for(user)
    CalendarSyncJob.perform_now(user.user_id, FIXTURE_WEEK_START, ZONE)
  end

  test "syncs the week for a connected paid account" do
    calls, record = recording(SyncWeekToCalendar::Result.new(written: 1, deleted: 0, error: nil))

    stubbing(SyncWeekToCalendar, :call, record) { run_for(users(:calendar)) }

    assert_equal 1, calls.size
  end

  test "does nothing for an account whose subscription lapsed after the job was enqueued" do
    users(:calendar).update!(subscription_period_end: 1.day.ago)
    calls, record = recording

    stubbing(SyncWeekToCalendar, :call, record) { run_for(users(:calendar)) }

    assert_empty calls
  end

  test "does nothing for an account that was never paid" do
    users(:calendar).update!(subscription_status: nil, subscription_period_end: nil)
    calls, record = recording

    stubbing(SyncWeekToCalendar, :call, record) { run_for(users(:calendar)) }

    assert_empty calls
  end

  test "does nothing for a user who has since disconnected" do
    users(:calendar).disconnect_calendar!
    calls, record = recording

    stubbing(SyncWeekToCalendar, :call, record) { run_for(users(:calendar)) }

    assert_empty calls
  end

  test "does nothing for a user who has since turned the switch off" do
    users(:calendar).update!(calendar_sync_enabled: false)
    calls, record = recording

    stubbing(SyncWeekToCalendar, :call, record) { run_for(users(:calendar)) }

    assert_empty calls
  end

  # A deleted account is not an error worth retrying: the week it was going to sync is gone too.
  test "does nothing for a user who no longer exists" do
    calls, record = recording

    stubbing(SyncWeekToCalendar, :call, record) do
      CalendarSyncJob.perform_now(-1, FIXTURE_WEEK_START, ZONE)
    end

    assert_empty calls
  end
end
