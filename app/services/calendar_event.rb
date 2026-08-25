# One task, as a Google Calendar event.
#
# The event says the three things a card says on the app's own calendars: what the task is, what it
# is working towards, and which role or dimension that came from. It is the same breakdown the
# dashboard's detail dialog renders (next-app/app/dashboard/_utils/events.ts), composed here because
# an event written server-side has no frontend to compose it.
class CalendarEvent
  # Marks an event as ours. Google indexes private extended properties, so this is also how a sync
  # finds what it wrote last time -- see SyncWeekToCalendar, which searches on MARKER rather than
  # trusting the ids it stored. It means a user's own events in the same calendar are never touched.
  MARKER_KEY = "habitflow".freeze
  MARKER_VALUE = "1".freeze
  MARKER = "#{MARKER_KEY}=#{MARKER_VALUE}".freeze

  TASK_KEY = "habitflow_task_id".freeze
  # The week an event belongs to, so a sync can ask Google for exactly this week's events. The time
  # window alone cannot: an event carries a zone rather than an offset, so the window has to be
  # widened by a day at each end to be safe in any zone, which would sweep in the neighbouring
  # weeks' Sunday and Monday -- and the reconcile deletes whatever it finds that this week no longer
  # wants. Without this key it would delete last week's Sunday every time.
  WEEK_KEY = "habitflow_week".freeze

  # Google's event palette is eleven fixed colours, so the app's hexes map onto it rather than
  # travelling. Banana is the reserved yellow: on every HabitFlow calendar a yellow card means the
  # task serves a goal marked a weekly priority, and nothing else may claim it -- the same rule
  # WEEKLY_PRIORITY_COLOR enforces in next-app/lib/role-colors.ts, extended onto Google's palette.
  WEEKLY_PRIORITY_COLOR_ID = "5"  # Banana
  FIXED_COLOR_ID = "9"            # Blueberry, for FIXED_COLOR #3b82f6
  UNLINKED_COLOR_ID = "8"         # Graphite
  ROLE_COLOR_IDS = {
    "primary" => "3",             # Grape,     #B13BFF
    "secondary" => "1",           # Lavender,  #471396
    "teal" => "7",                # Peacock,   #14b8a6
    "rose" => "4",                # Flamingo,  #f43f5e
    "orange" => "6"               # Tangerine, #f97316
  }.freeze
  DIMENSION_COLOR_IDS = {
    "physical" => "6",
    "spiritual" => "3",
    "mental" => "7",
    "social" => "4"
  }.freeze

  # The two filters a sync searches Google with: every event we own, narrowed to one week.
  def self.week_property(week_start) = "#{WEEK_KEY}=#{week_start.iso8601}"

  # Which task an event belongs to, read back out of the property rather than out of our own
  # records -- see SyncWeekToCalendar, which treats the stored id as a cache and this as the truth.
  def self.task_id_of(event) = event.dig("extendedProperties", "private", TASK_KEY)

  def initialize(task, week_start:, time_zone:)
    @task = task
    @week_start = week_start
    @time_zone = time_zone
  end

  def to_h
    {
      summary: @task.task_name,
      description: description,
      start: { dateTime: date_time(@task.start_time), timeZone: @time_zone },
      end: { dateTime: date_time(@task.end_time), timeZone: @time_zone },
      colorId: color_id,
      extendedProperties: {
        private: {
          MARKER_KEY => MARKER_VALUE,
          TASK_KEY => @task.task_id.to_s,
          WEEK_KEY => @week_start.iso8601
        }
      },
      # A planned week is thirty events. Default reminders would be thirty notifications, which is
      # not what someone asked for by exporting a schedule -- and HabitFlow prompts its own
      # End-of-Day check-in already.
      reminders: { useDefault: false, overrides: [] }
    }
  end

  private

  # A task stores day_of_week and a bare wall-clock time; it has no date column, so the week it
  # belongs to is what turns "day 2" into a date. The zone is the browser's, sent per request --
  # the server stores none, for the same reason it never derives "the current week" itself.
  def date_time(time)
    date = @week_start + @task.day_of_week
    "#{date.iso8601}T#{time.strftime('%H:%M:%S')}"
  end

  def description
    lines = link_lines
    lines << "" << @task.description.strip if @task.is_fixed_appointment? && @task.description.present?
    lines << "" << priority_lines.join("\n") if priority_lines.any?
    lines.join("\n")
  end

  def link_lines
    return [ "Fixed appointment" ] if @task.is_fixed_appointment?

    if (goal = @task.goal)
      return [ "Goal: #{goal.description}", "Role: #{goal.role&.role_name}" ].compact_blank
    end

    if (activity = @task.sharpen_the_saw_activity)
      return [ "Activity: #{activity.activity_description}",
               "Sharpen the Saw: #{activity.dimension_label}" ]
    end

    [ "Task" ]
  end

  def priority_lines
    @priority_lines ||= [
      ("Weekly priority" if @task.goal&.is_weekly_priority?),
      ("Daily priority" if @task.is_daily_priority?)
    ].compact
  end

  def color_id
    return WEEKLY_PRIORITY_COLOR_ID if @task.goal&.is_weekly_priority?
    return FIXED_COLOR_ID if @task.is_fixed_appointment?
    return ROLE_COLOR_IDS.fetch(@task.goal.role&.color_id, UNLINKED_COLOR_ID) if @task.goal
    return DIMENSION_COLOR_IDS.fetch(@task.sharpen_the_saw_activity.dimension, UNLINKED_COLOR_ID) if @task.sharpen_the_saw_activity

    UNLINKED_COLOR_ID
  end
end
