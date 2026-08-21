require "test_helper"

class EveningReflectionTest < ActiveSupport::TestCase
  test "requires content" do
    reflection = EveningReflection.new(weekly_plan: weekly_plans(:one), day_of_week: 5, content: "")
    assert_not reflection.valid?
    assert_includes reflection.errors[:content], "can't be blank"
  end

  test "accepts every day of the week and nothing outside it" do
    (0..6).each do |day|
      reflection = EveningReflection.new(weekly_plan: weekly_plans(:two), day_of_week: day, content: "ok")
      assert_predicate reflection, :valid?, "day #{day} should be a valid day of the week"
    end

    [ -1, 7 ].each do |day|
      reflection = EveningReflection.new(weekly_plan: weekly_plans(:two), day_of_week: day, content: "ok")
      assert_not reflection.valid?, "day #{day} should be rejected"
    end
  end

  test "a week holds at most one reflection per day" do
    duplicate = EveningReflection.new(weekly_plan: weekly_plans(:one), day_of_week: 0, content: "second go")
    assert_not duplicate.valid?

    # The same day in a different week is a different reflection.
    assert_predicate EveningReflection.new(weekly_plan: weekly_plans(:two), day_of_week: 0, content: "ok"), :valid?
  end

  test "the one-per-day rule is enforced by the database, not only the validation" do
    assert_raises ActiveRecord::RecordNotUnique do
      EveningReflection.insert_all!([
        { weekly_plan_id: weekly_plans(:one).weekly_plan_id, day_of_week: 0, content: "bypasses validation" }
      ])
    end
  end

  test "is destroyed with its weekly plan" do
    plan = weekly_plans(:one)
    assert_difference -> { EveningReflection.count }, -2 do
      plan.destroy
    end
  end
end
