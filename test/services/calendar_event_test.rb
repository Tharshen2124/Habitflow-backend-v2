require "test_helper"

class CalendarEventTest < ActiveSupport::TestCase
  WEEK = Date.new(2026, 8, 17)
  ZONE = "Asia/Kuala_Lumpur".freeze

  def body_for(task, time_zone: ZONE)
    CalendarEvent.new(task, week_start: WEEK, time_zone: time_zone).to_h
  end

  test "the summary is the task name, unadorned" do
    assert_equal "Write the discussion", body_for(tasks(:calendar_priority))[:summary]
  end

  test "a goal-linked task names its goal and its role" do
    description = body_for(tasks(:calendar_plain))[:description]

    assert_includes description, "Goal: Read three papers"
    assert_includes description, "Role: Researcher"
  end

  test "an activity-linked task names its activity and the dimension's display name" do
    description = body_for(tasks(:calendar_activity))[:description]

    assert_includes description, "Activity: Call home on Sundays"
    # The whole reason DIMENSION_LABELS had to move to the server: the column holds "social".
    assert_includes description, "Sharpen the Saw: Social / Emotional"
  end

  test "a fixed appointment says so and carries its own notes" do
    description = body_for(tasks(:calendar_fixed))[:description]

    assert_includes description, "Fixed appointment"
    assert_includes description, "Bring the draft"
    assert_not_includes description, "Goal:"
  end

  test "the two priorities are named, and are separate claims" do
    assert_includes body_for(tasks(:calendar_priority))[:description], "Weekly priority"
    assert_not_includes body_for(tasks(:calendar_priority))[:description], "Daily priority"

    # tasks(:calendar_plain) is a daily priority under a goal that is not a weekly one.
    assert_includes body_for(tasks(:calendar_plain))[:description], "Daily priority"
    assert_not_includes body_for(tasks(:calendar_plain))[:description], "Weekly priority"
  end

  test "a weekly priority takes Banana, beating its role's own colour" do
    assert_equal "rose", roles(:calendar).color_id
    assert_equal CalendarEvent::WEEKLY_PRIORITY_COLOR_ID, body_for(tasks(:calendar_priority))[:colorId]
  end

  test "an ordinary goal task takes its role's colour" do
    assert_equal CalendarEvent::ROLE_COLOR_IDS.fetch("rose"), body_for(tasks(:calendar_plain))[:colorId]
  end

  test "an activity task takes its dimension's colour and a fixed appointment takes blue" do
    assert_equal CalendarEvent::DIMENSION_COLOR_IDS.fetch("social"), body_for(tasks(:calendar_activity))[:colorId]
    assert_equal CalendarEvent::FIXED_COLOR_ID, body_for(tasks(:calendar_fixed))[:colorId]
  end

  test "nothing but a weekly priority may claim Banana" do
    claimed = CalendarEvent::ROLE_COLOR_IDS.values + CalendarEvent::DIMENSION_COLOR_IDS.values +
              [ CalendarEvent::FIXED_COLOR_ID, CalendarEvent::UNLINKED_COLOR_ID ]

    assert_not_includes claimed, CalendarEvent::WEEKLY_PRIORITY_COLOR_ID
  end

  test "day_of_week is an offset from the week's Monday" do
    assert_equal "2026-08-17T09:00:00", body_for(tasks(:calendar_priority))[:start][:dateTime]
    # Day 6 is the Sunday of this week, not the Monday of the next one.
    assert_equal "2026-08-23T19:00:00", body_for(tasks(:calendar_activity))[:start][:dateTime]
    assert_equal "2026-08-23T19:30:00", body_for(tasks(:calendar_activity))[:end][:dateTime]
  end

  test "the time carries no offset and the zone travels beside it" do
    start = body_for(tasks(:calendar_priority))[:start]

    # An offset composed server-side would be a timezone the server does not hold. RFC3339 allows
    # the offset to be omitted precisely when timeZone is given.
    assert_not_includes start[:dateTime], "+"
    assert_equal ZONE, start[:timeZone]
    assert_equal "Europe/London", body_for(tasks(:calendar_priority), time_zone: "Europe/London")[:start][:timeZone]
  end

  test "every event is marked as ours and names its task and its week" do
    private_props = body_for(tasks(:calendar_priority))[:extendedProperties][:private]

    assert_equal CalendarEvent::MARKER_VALUE, private_props[CalendarEvent::MARKER_KEY]
    assert_equal tasks(:calendar_priority).task_id.to_s, private_props[CalendarEvent::TASK_KEY]
    assert_equal "2026-08-17", private_props[CalendarEvent::WEEK_KEY]
  end

  test "no reminders, so a synced week does not become thirty notifications" do
    assert_equal({ useDefault: false, overrides: [] }, body_for(tasks(:calendar_priority))[:reminders])
  end
end
