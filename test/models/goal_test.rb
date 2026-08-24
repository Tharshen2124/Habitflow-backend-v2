require "test_helper"

class GoalTest < ActiveSupport::TestCase
  test "requires a description" do
    goal = Goal.new(role: roles(:one), weekly_plan: weekly_plans(:one))
    assert_not goal.valid?
    assert_includes goal.errors[:description], "can't be blank"
  end

  test "requires a weekly plan" do
    goal = Goal.new(role: roles(:one), description: "Ship the thing")
    assert_not goal.valid?
    assert_includes goal.errors[:weekly_plan], "must exist"
  end

  test "active and dropped scopes split on deleted_at" do
    goal = goals(:one)
    assert_includes Goal.active, goal

    goal.update!(deleted_at: Time.current)

    assert_not_includes Goal.active, goal
    assert_includes Goal.dropped, goal
    assert_predicate goal, :dropped?
  end

  # "Achieved" is read off the tasks, not off `goals.is_completed` -- that column had no writer, so
  # every figure built on it read zero.
  test "achieved covers a goal whose every task is done" do
    assert_includes Goal.achieved, goals(:past_achieved)
  end

  test "achieved excludes a goal with an outstanding task" do
    assert_not_includes Goal.achieved, goals(:past_missed)
  end

  test "one unfinished task is enough to keep a goal out of achieved" do
    goal = goals(:past_achieved)
    goal.tasks.create!(
      user: users(:three), weekly_plan: weekly_plans(:past), task_name: "Proofread it",
      day_of_week: 4, start_time: "09:00", end_time: "10:00"
    )

    assert_not_includes Goal.achieved, goal
  end

  # The case the old stored column got wrong for free: nothing scheduled is not the same as
  # everything done, and a vacuous truth would have marked every unplanned goal achieved.
  test "achieved excludes a goal nobody scheduled a task for" do
    goal = goals(:past_missed)
    goal.tasks.destroy_all

    assert_empty goal.tasks
    assert_not_includes Goal.achieved, goal
  end
end
