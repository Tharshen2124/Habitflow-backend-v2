require "test_helper"

class SyncWeekToCalendarTest < ActiveSupport::TestCase
  WEEK = Date.new(2026, 8, 17)
  ZONE = "Asia/Kuala_Lumpur".freeze

  setup do
    @user = users(:calendar)
    @inserts = []
    @patches = []
    @deletes = []
  end

  # Google echoes an event back with an offset on dateTime and the zone alongside it, never the
  # bare wall-clock string we sent. Replaying that faithfully is the whole point of this helper:
  # a stub that echoed our own strings back would hide the diff bug `unchanged?` exists to avoid.
  def as_remote(body, id:)
    {
      "id" => id,
      "summary" => body[:summary],
      "description" => body[:description],
      "colorId" => body[:colorId],
      "start" => google_time(body[:start]),
      "end" => google_time(body[:end]),
      "extendedProperties" => { "private" => body[:extendedProperties][:private].transform_keys(&:to_s) }
    }
  end

  def google_time(part)
    { "dateTime" => ActiveSupport::TimeZone[part[:timeZone]].parse(part[:dateTime]).iso8601,
      "timeZone" => part[:timeZone] }
  end

  def event_for(task, id: "evt-#{task.task_id}")
    as_remote(CalendarEvent.new(task, week_start: WEEK, time_zone: ZONE).to_h, id: id)
  end

  def sync(existing: [], list_error: nil, user: @user, week: WEEK)
    list = if list_error
      GoogleCalendarClient::Result.new(body: nil, error: list_error)
    else
      GoogleCalendarClient::Result.new(body: existing, error: nil)
    end

    stubbing_all(GoogleCalendarClient, {
      list_events: list,
      insert_event: ->(_t, _c, body) {
        @inserts << body
        GoogleCalendarClient::Result.new(body: { "id" => "new-#{@inserts.size}" }, error: nil)
      },
      patch_event: ->(_t, _c, event_id, body) {
        @patches << [ event_id, body ]
        GoogleCalendarClient::Result.new(body: { "id" => event_id }, error: nil)
      },
      delete_event: ->(_t, _c, event_id) {
        @deletes << event_id
        GoogleCalendarClient::Result.new(body: {}, error: nil)
      }
    }) do
      SyncWeekToCalendar.call(user: user, week_start: week, time_zone: ZONE)
    end
  end

  test "an empty calendar gets one event per task, and the ids are kept" do
    result = sync

    assert result.ok?
    assert_equal 4, @inserts.size
    assert_equal 4, result.written
    assert_equal 0, result.deleted
    assert_equal "synced", tasks(:calendar_priority).reload.sync_status
    assert tasks(:calendar_priority).google_calendar_event_id.present?
  end

  # The invariant the whole reconcile exists to protect. Without `unchanged?` this is four patches,
  # on every sync, forever.
  test "running again with nothing changed writes nothing" do
    existing = @user.tasks.map { |task| event_for(task) }

    result = sync(existing: existing)

    assert result.ok?
    assert_empty @inserts
    assert_empty @patches
    assert_empty @deletes
    assert_equal 0, result.written
  end

  test "a renamed task is patched, and only that one" do
    existing = @user.tasks.map { |task| event_for(task) }
    tasks(:calendar_plain).update!(task_name: "Read Hutchins 2019 again")

    result = sync(existing: existing)

    assert_equal 1, @patches.size
    assert_equal "evt-#{tasks(:calendar_plain).task_id}", @patches.first.first
    assert_empty @inserts
    assert_equal 1, result.written
  end

  test "a task that has left the week has its event deleted" do
    existing = @user.tasks.map { |task| event_for(task) }
    gone = tasks(:calendar_activity)
    gone_event_id = "evt-#{gone.task_id}"
    gone.destroy!

    result = sync(existing: existing)

    assert_equal [ gone_event_id ], @deletes
    assert_equal 1, result.deleted
  end

  test "excluding a role takes its tasks off the calendar and leaves the rest alone" do
    existing = @user.tasks.map { |task| event_for(task) }
    @user.update!(export_preference: { "excluded_role_ids" => [ roles(:calendar).role_id ] })

    sync(existing: existing)

    assert_equal 2, @deletes.size
    assert_includes @deletes, "evt-#{tasks(:calendar_priority).task_id}"
    assert_includes @deletes, "evt-#{tasks(:calendar_plain).task_id}"
    assert_not_includes @deletes, "evt-#{tasks(:calendar_activity).task_id}"
  end

  test "unticking fixed appointments deletes only the fixed appointment" do
    existing = @user.tasks.map { |task| event_for(task) }
    @user.update!(export_preference: { "fixed_appointments" => false })

    sync(existing: existing)

    assert_equal [ "evt-#{tasks(:calendar_fixed).task_id}" ], @deletes
  end

  test "excluding a dimension deletes its activity task" do
    existing = @user.tasks.map { |task| event_for(task) }
    @user.update!(export_preference: { "excluded_dimensions" => [ "social" ] })

    sync(existing: existing)

    assert_equal [ "evt-#{tasks(:calendar_activity).task_id}" ], @deletes
  end

  # A sync that failed part-way, or two saves racing through the job queue, can leave two events
  # for one task. Dropping the extras here is what makes that self-healing.
  test "a duplicated event is cleaned up, and the surviving one is not rewritten" do
    task = tasks(:calendar_priority)
    existing = @user.tasks.map { |t| event_for(t) } << event_for(task, id: "zzz-duplicate")

    sync(existing: existing)

    assert_equal [ "zzz-duplicate" ], @deletes
    assert_empty @patches
    assert_empty @inserts
  end

  test "an event we did not write is left entirely alone" do
    theirs = { "id" => "theirs", "summary" => "Dentist", "extendedProperties" => { "private" => {} } }
    existing = @user.tasks.map { |task| event_for(task) } << theirs

    sync(existing: existing)

    assert_empty @deletes
  end

  # ArchiveGoal removes only the *unfinished* tasks, so a completed one outlives its goal. The
  # exporter reads goals and roles without `.active` for exactly this case -- the same exception
  # /history makes, and for the same reason.
  test "a completed task under a dropped goal keeps its event, its role name and its colour" do
    tasks(:calendar_plain).update!(is_completed: true)
    goals(:calendar_plain).update!(deleted_at: Time.current)
    roles(:calendar).update!(deleted_at: Time.current)

    sync

    body = @inserts.find { |b| b[:summary] == "Read Hutchins 2019" }
    assert_includes body[:description], "Role: Researcher"
    assert_equal CalendarEvent::ROLE_COLOR_IDS.fetch("rose"), body[:colorId]
  end

  # A plan row existing is the app's only answer to "is this week planned?", and /weekly-plan picks
  # which week to offer from that answer. A sync that filed one would tell the user they had
  # already planned a week they had not.
  test "an unplanned week is a no-op and does not bring a plan into existence" do
    unplanned = Date.new(2026, 9, 7)
    assert_nil @user.weekly_plans.find_by(start_date: unplanned)

    assert_no_difference "WeeklyPlan.count" do
      result = sync(week: unplanned)
      assert result.ok?
      assert_equal 0, result.written
    end
    assert_empty @inserts
  end

  test "a failed listing aborts the week without writing anything" do
    result = sync(list_error: :unauthorized)

    assert_not result.ok?
    assert_equal :unauthorized, result.error
    assert_empty @inserts
    assert_empty @deletes
  end

  test "a user with no grant never reaches Google" do
    @user.disconnect_calendar!

    result = stubbing(GoogleCalendarClient, :list_events, ->(*) { flunk "Google must not be called" }) do
      SyncWeekToCalendar.call(user: @user, week_start: WEEK, time_zone: ZONE)
    end

    assert_equal :disconnected, result.error
  end

  # Advisory locks are held by the connection, so this counts the ones this backend holds. The test
  # and the service share a connection, which is what lets the stub see the lock from inside.
  def advisory_locks_held
    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted"
    ).to_i
  end

  # The duplicate this exists to prevent: /weekly-plan/edit POSTs tasks and fixed appointments at
  # once, so two jobs reconciled one week at the same moment. Both listed before either inserted,
  # so one new task became two events on the calendar. Listing has to happen under the lock for the
  # second run to see what the first one wrote.
  test "lists and writes holding the week's advisory lock, and releases it afterwards" do
    during = nil

    stubbing_all(GoogleCalendarClient, {
      list_events: ->(*) {
        during = advisory_locks_held
        GoogleCalendarClient::Result.new(body: [], error: nil)
      },
      insert_event: ->(*) { GoogleCalendarClient::Result.new(body: { "id" => "e1" }, error: nil) }
    }) do
      assert SyncWeekToCalendar.call(user: @user, week_start: WEEK, time_zone: ZONE).ok?
    end

    assert_equal 1, during, "the reconcile must list Google while holding the week's lock"
    assert_equal 0, advisory_locks_held, "the lock must be released once the reconcile is done"
  end

  # An exception mid-reconcile must not wedge the week: every later sync would block on the lock
  # forever, and the failure would look like Google having gone quiet.
  test "releases the lock when the reconcile raises" do
    stubbing(GoogleCalendarClient, :list_events, ->(*) { raise IOError, "connection reset" }) do
      assert_raises(IOError) { SyncWeekToCalendar.call(user: @user, week_start: WEEK, time_zone: ZONE) }
    end

    assert_equal 0, advisory_locks_held
  end

  # A week with no plan returns before the lock is taken, so an unplanned week costs nothing.
  test "releases the lock when the listing fails" do
    sync(list_error: :unavailable)

    assert_equal 0, advisory_locks_held
  end
end
