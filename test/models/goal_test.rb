require "test_helper"

class GoalTest < ActiveSupport::TestCase
  test "requires a description" do
    goal = Goal.new(role: roles(:one))
    assert_not goal.valid?
    assert_includes goal.errors[:description], "can't be blank"
  end
end
