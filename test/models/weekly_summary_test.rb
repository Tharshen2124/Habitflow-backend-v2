require "test_helper"

class WeeklySummaryTest < ActiveSupport::TestCase
  def build(plan: weekly_plans(:one), **overrides)
    WeeklySummary.new({ weekly_plan: plan, content: "A steady week.", model: "gemini-2.5-flash",
                        generated_at: Time.current }.merge(overrides))
  end

  test "requires content and the model that wrote it" do
    assert_not build(content: "").valid?
    assert_not build(model: "").valid?
    assert_predicate build, :valid?
  end

  test "a weekly plan can only ever have one summary" do
    build.save!

    assert_not build.valid?, "a second summary for the same week should be rejected"
    assert_predicate build(plan: weekly_plans(:two)), :valid?
  end

  test "the once-per-week rule is enforced by the database, not only the validation" do
    build.save!

    assert_raises ActiveRecord::RecordNotUnique do
      WeeklySummary.insert_all!([
        { weekly_plan_id: weekly_plans(:one).weekly_plan_id, content: "race", model: "m",
          generated_at: Time.current }
      ])
    end
  end

  test "is destroyed with its weekly plan" do
    build.save!
    assert_difference -> { WeeklySummary.count }, -1 do
      weekly_plans(:one).destroy
    end
  end
end
