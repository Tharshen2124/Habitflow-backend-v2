require "test_helper"

class WeeklyPlanTest < ActiveSupport::TestCase
  test "start_date must be a Monday" do
    plan = WeeklyPlan.new(user: users(:one), start_date: Date.new(2026, 8, 18)) # a Tuesday
    assert_not plan.valid?
    assert_includes plan.errors[:start_date], "must be a Monday"
  end

  test "end_date is derived as start_date + 6" do
    plan = WeeklyPlan.create!(user: users(:one), start_date: Date.new(2026, 8, 24))
    assert_equal Date.new(2026, 8, 30), plan.end_date
  end

  test "for! creates the plan for a week the user does not have yet" do
    assert_difference -> { users(:one).weekly_plans.count }, 1 do
      WeeklyPlan.for!(users(:one), Date.new(2026, 8, 24))
    end
  end

  test "for! is idempotent, so every onboarding step lands in the same plan" do
    first = WeeklyPlan.for!(users(:one), Date.new(2026, 8, 24))

    assert_no_difference -> { users(:one).weekly_plans.count } do
      assert_equal first.weekly_plan_id, WeeklyPlan.for!(users(:one), Date.new(2026, 8, 24)).weekly_plan_id
    end
  end

  test "for! scopes to the user, so two users can plan the same week" do
    WeeklyPlan.for!(users(:one), Date.new(2026, 8, 24))

    assert_difference -> { users(:two).weekly_plans.count }, 1 do
      WeeklyPlan.for!(users(:two), Date.new(2026, 8, 24))
    end
  end

  test "a user cannot have two plans for the same week" do
    assert_raises ActiveRecord::RecordNotUnique do
      WeeklyPlan.insert_all!([
        { user_id: users(:one).user_id, start_date: Date.new(2026, 8, 24), end_date: Date.new(2026, 8, 30) },
        { user_id: users(:one).user_id, start_date: Date.new(2026, 8, 24), end_date: Date.new(2026, 8, 30) }
      ])
    end
  end
end
