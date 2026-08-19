require "test_helper"

class GoalCarryoverTest < ActiveSupport::TestCase
  # find-or-create, so calling this twice in one test lands both goals in the same later week.
  def next_week_goal(description: "Continue the milestone")
    plan = WeeklyPlan.for!(users(:one), Date.new(2026, 8, 24))
    roles(:one).goals.create!(description: description, weekly_plan: plan)
  end

  test "links a goal to its continuation in a later week" do
    carryover = GoalCarryover.create!(source_goal: goals(:one), destination_goal: next_week_goal)

    assert_equal carryover, goals(:one).reload.carried_to
    assert_equal goals(:one), carryover.destination_goal.carried_from.source_goal
  end

  test "rejects a goal carried forward into itself" do
    carryover = GoalCarryover.new(source_goal: goals(:one), destination_goal: goals(:one))

    assert_not carryover.valid?
    assert_includes carryover.errors[:destination_goal_id], "must be a different goal"
  end

  # Without this a chain can loop back on itself and walking it never terminates.
  test "rejects a destination in the same week or earlier" do
    same_week = roles(:one).goals.create!(description: "Sibling", weekly_plan: weekly_plans(:one))
    carryover = GoalCarryover.new(source_goal: goals(:one), destination_goal: same_week)

    assert_not carryover.valid?
    assert_includes carryover.errors[:destination_goal_id],
                    "must belong to a later week than the source goal"
  end

  test "a goal can only be carried forward once" do
    GoalCarryover.create!(source_goal: goals(:one), destination_goal: next_week_goal)
    duplicate = GoalCarryover.new(source_goal: goals(:one), destination_goal: next_week_goal(description: "Another"))

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:source_goal_id], "has already been taken"
  end

  test "a goal can only continue one predecessor" do
    destination = next_week_goal
    GoalCarryover.create!(source_goal: goals(:one), destination_goal: destination)
    duplicate = GoalCarryover.new(source_goal: goals(:two), destination_goal: destination)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:destination_goal_id], "has already been taken"
  end
end
