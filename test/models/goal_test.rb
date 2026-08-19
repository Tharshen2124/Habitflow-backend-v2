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

  # The three outcomes analytics reports are derived, not stored: a dropped goal is never silently
  # removed from the week it belonged to.
  test "outcome is dropped for an archived goal even when it was completed" do
    goal = goals(:one)
    goal.update!(is_completed: true, deleted_at: Time.current)

    assert_equal :dropped, goal.outcome(as_of: Date.new(2026, 8, 31))
  end

  test "outcome is achieved for a completed goal" do
    goals(:one).update!(is_completed: true)

    assert_equal :achieved, goals(:one).outcome(as_of: Date.new(2026, 8, 31))
  end

  test "outcome is missed only once the week has ended" do
    goal = goals(:one)

    # weekly_plans(:one) covers 17-23 Aug 2026.
    assert_equal :open, goal.outcome(as_of: Date.new(2026, 8, 20))
    assert_equal :open, goal.outcome(as_of: Date.new(2026, 8, 23))
    assert_equal :missed, goal.outcome(as_of: Date.new(2026, 8, 24))
  end
end
