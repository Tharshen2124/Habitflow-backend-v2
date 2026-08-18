require "test_helper"

class TaskTest < ActiveSupport::TestCase
  def valid_appointment_attrs
    {
      user: users(:one),
      task_name: "Dentist",
      is_fixed_appointment: true,
      day_of_week: 1,
      start_time: "10:00",
      end_time: "11:00"
    }
  end

  test "valid fixed appointment" do
    assert Task.new(valid_appointment_attrs).valid?
  end

  test "end_time must be after start_time" do
    task = Task.new(valid_appointment_attrs.merge(start_time: "11:00", end_time: "10:00"))
    assert_not task.valid?
    assert_includes task.errors[:end_time], "must be after start time"
  end

  test "day_of_week must be within 0..6" do
    task = Task.new(valid_appointment_attrs.merge(day_of_week: 7))
    assert_not task.valid?
  end

  test "fixed appointment cannot have a goal" do
    task = Task.new(valid_appointment_attrs.merge(goal: goals(:one)))
    assert_not task.valid?
    assert_includes task.errors[:goal_id], "must be blank for a fixed appointment"
  end

  test "fixed appointment cannot have a sharpen the saw activity" do
    task = Task.new(valid_appointment_attrs.merge(sharpen_the_saw_activity: sharpen_the_saw_activities(:one)))
    assert_not task.valid?
    assert_includes task.errors[:sharpen_the_saw_activity_id], "must be blank for a fixed appointment"
  end

  test "fixed appointment cannot be a daily priority" do
    task = Task.new(valid_appointment_attrs.merge(is_daily_priority: true))
    assert_not task.valid?
    assert_includes task.errors[:is_daily_priority], "cannot be set for a fixed appointment"
  end

  test "fixed appointment cannot have a daily_priority_date" do
    task = Task.new(valid_appointment_attrs.merge(daily_priority_date: Date.today))
    assert_not task.valid?
    assert_includes task.errors[:daily_priority_date], "must be blank for a fixed appointment"
  end
end
