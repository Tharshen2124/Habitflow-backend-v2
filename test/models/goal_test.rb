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
end
