# Makes one week on the user's HabitFlow calendar match one week in the app.
#
# A full reconcile rather than a stream of edits, and deliberately so: a task can leave a week
# through half a dozen routes -- deleted on /weekly-plan/edit, taken off by ArchiveGoal when its
# goal is dropped, or simply no longer wanted because its role was unticked in /settings -- and
# hooking every one of them would mean six chances to forget the calendar. Comparing what is there
# with what should be there covers all of them and is safe to run twice.
#
# The invariant worth protecting: running this twice with nothing changed in between costs one
# request -- the list -- and writes nothing.
class SyncWeekToCalendar
  Result = Data.define(:written, :deleted, :error) do
    def ok? = error.nil?
  end

  def self.call(user:, week_start:, time_zone:)
    new(user, week_start, time_zone).call
  end

  def initialize(user, week_start, time_zone)
    @user = user
    @week_start = week_start
    @time_zone = time_zone
    @written = 0
    @deleted = 0
  end

  def call
    return failure(:disconnected) unless @user.calendar_connected?

    @token = CalendarAccess.token_for(@user)
    return failure(:disconnected) if @token.blank?

    # find_by, never WeeklyPlan.for!. A plan row existing is the app's only answer to "is this week
    # planned?", and /weekly-plan picks which week to offer from that answer -- so a sync that filed
    # one would quietly tell the user they had already planned a week they had not.
    plan = @user.weekly_plans.find_by(start_date: @week_start)
    return Result.new(written: 0, deleted: 0, error: nil) if plan.nil?

    existing = fetch_existing
    existing = recreate_calendar if existing.error == :not_found
    return failure(existing.error) unless existing.ok?

    reconcile(plan, existing.body)
  end

  private

  def reconcile(plan, events)
    prefs = CalendarExportPreference.new(@user.export_preference)
    # The same eager-load WeeklyPlansController uses: a description names the goal's role and the
    # activity's dimension, so without it a thirty-task week is ninety extra queries. Deliberately
    # no `.active` on either -- see CalendarEvent, and HistoryController before it.
    tasks = plan.tasks.includes(:sharpen_the_saw_activity, goal: :role).to_a
    wanted = tasks.select { |task| prefs.exports?(task) }

    matched, duplicates = index_by_task_id(events)
    # Two events carrying one task id means an earlier run inserted twice -- a sync that failed
    # part-way, or two saves racing through the job queue. Dropping the extras here is what makes
    # that self-healing, and is why this needs no lock.
    duplicates.each { |event| remove(event, tasks) }

    wanted.each { |task| write(task, matched[task.task_id.to_s]) }

    # Anything left over is a task this week no longer has, or no longer wants exported. Both mean
    # the event goes -- which is what makes unticking a role in /settings clear the calendar.
    wanted_ids = wanted.map { |task| task.task_id.to_s }
    matched.except(*wanted_ids).each_value { |event| remove(event, tasks) }

    Result.new(written: @written, deleted: @deleted, error: nil)
  end

  def write(task, event)
    body = CalendarEvent.new(task, week_start: @week_start, time_zone: @time_zone).to_h

    if event && unchanged?(event, body)
      # Nothing to send. The id is still worth reconciling, because it is the only way to answer
      # "which Google event is this task" from the console.
      stamp(task, event["id"]) if task.google_calendar_event_id != event["id"]
      return
    end

    result = event ? patch_or_insert(event, body) : GoogleCalendarClient.insert_event(@token, @user.calendar_id, body)

    if result.ok?
      @written += 1
      stamp(task, result.body["id"])
    else
      # One task failing is not the week failing: the other twenty-nine still belong on the
      # calendar, and the row records which one to look at.
      task.update_columns(sync_status: "failed")
      Rails.logger.error("Calendar sync failed for task #{task.task_id}: #{result.error}")
    end
  end

  # A 404 means the user deleted this event in Google between the list and the patch. Inserting is
  # the right answer -- HabitFlow owns these events, and the calendar says so.
  def patch_or_insert(event, body)
    result = GoogleCalendarClient.patch_event(@token, @user.calendar_id, event["id"], body)
    return result unless result.error == :not_found

    GoogleCalendarClient.insert_event(@token, @user.calendar_id, body)
  end

  # Whether Google already holds what we would send. Without this every sync would patch every
  # event of every week, forever: thirty writes where none were needed.
  def unchanged?(event, body)
    event["summary"] == body[:summary] &&
      event["description"] == body[:description] &&
      event["colorId"] == body[:colorId] &&
      same_time?(event["start"], body[:start]) &&
      same_time?(event["end"], body[:end])
  end

  # We send "2026-08-24T07:00:00" with a separate timeZone; Google always echoes back
  # "2026-08-24T07:00:00+08:00". Comparing those two strings never matches, so a naive diff would
  # patch everything on every run and the bug would look like Google ignoring our writes. The
  # instant and the zone are the two things that actually have to agree -- the zone as well as the
  # instant, because syncing the same wall-clock week from a new timezone *should* rewrite it.
  def same_time?(remote, local)
    return false if remote.nil? || remote["timeZone"] != local[:timeZone]

    zone = ActiveSupport::TimeZone[local[:timeZone]]
    return false if zone.nil?

    zone.parse(local[:dateTime]) == Time.iso8601(remote["dateTime"].to_s)
  rescue ArgumentError
    false
  end

  def remove(event, tasks)
    result = GoogleCalendarClient.delete_event(@token, @user.calendar_id, event["id"])
    return unless result.ok?

    @deleted += 1
    task_id = CalendarEvent.task_id_of(event)
    # The task usually no longer exists -- that is why its event is going. When it does, the stored
    # id has to go with the event or the next sync would patch something that is not there.
    tasks.find { |task| task.task_id.to_s == task_id }
         &.update_columns(google_calendar_event_id: nil, sync_status: nil)
  end

  # update_columns rather than update!: nothing about the task itself changed, and running Task's
  # four validations -- one of which loads the goal -- thirty times to write one string each is
  # waste.
  def stamp(task, event_id)
    task.update_columns(google_calendar_event_id: event_id, sync_status: "synced")
  end

  def fetch_existing
    GoogleCalendarClient.list_events(
      @token, @user.calendar_id,
      # Widened a day at each end because an event carries a zone rather than an offset, so its
      # real instant depends on where the user was. The week extended property is what makes the
      # result exact; this window only keeps the request small.
      time_min: "#{(@week_start - 1).iso8601}T00:00:00Z",
      time_max: "#{(@week_start + 8).iso8601}T00:00:00Z",
      properties: [ CalendarEvent::MARKER, CalendarEvent.week_property(@week_start) ]
    )
  end

  # The calendar is gone -- deleted by hand in Google. Rebuild it and carry on against an empty
  # week rather than failing: the user asked for their plan to be on a calendar, and the one they
  # deleted was ours to replace.
  def recreate_calendar
    Rails.logger.warn("HabitFlow calendar missing for user #{@user.user_id}; recreating")
    return GoogleCalendarClient::Result.new(body: nil, error: :unavailable) if
      CalendarAccess.ensure_calendar(@user, @token, @time_zone, recreate: true).nil?

    GoogleCalendarClient::Result.new(body: [], error: nil)
  end

  # Keyed on the extended property rather than on tasks.google_calendar_event_id, which is a cache
  # and can be stale -- an event deleted by hand in Google leaves an id behind that would make every
  # later sync patch a 404. Reading the ids back from Google means the task is simply re-inserted.
  # Returns the one event to keep per task, and the extras to delete.
  def index_by_task_id(events)
    # An event on our calendar carrying no task id was put there by the user. Left entirely alone:
    # they may well have dropped something into the HabitFlow calendar on purpose.
    ours = events.select { |event| CalendarEvent.task_id_of(event).present? }
    grouped = ours.group_by { |event| CalendarEvent.task_id_of(event) }

    matched = grouped.transform_values { |group| group.min_by { |event| event["id"].to_s } }
    duplicates = grouped.values.flat_map { |group| group.sort_by { |event| event["id"].to_s }.drop(1) }
    [ matched, duplicates ]
  end

  def failure(error) = Result.new(written: @written, deleted: @deleted, error: error)
end
