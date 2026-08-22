require "test_helper"

class CheckInTest < ActiveSupport::TestCase
  test "records only the two outcomes a night can have" do
    [ CheckIn::COMPLETED, CheckIn::SKIPPED ].each do |status|
      assert_predicate CheckIn.new(weekly_plan: weekly_plans(:one), day_of_week: 5, status: status), :valid?
    end

    invalid = CheckIn.new(weekly_plan: weekly_plans(:one), day_of_week: 5, status: "postponed")
    assert_not invalid.valid?
    assert_includes invalid.errors[:status], "is not included in the list"
  end

  test "accepts every day of the week and nothing outside it" do
    (0..6).each do |day|
      check_in = CheckIn.new(weekly_plan: weekly_plans(:two), day_of_week: day, status: CheckIn::COMPLETED)
      assert_predicate check_in, :valid?, "day #{day} should be a valid day of the week"
    end

    [ -1, 7 ].each do |day|
      check_in = CheckIn.new(weekly_plan: weekly_plans(:two), day_of_week: day, status: CheckIn::COMPLETED)
      assert_not check_in.valid?, "day #{day} should be rejected"
    end
  end

  test "a week holds at most one check-in per day" do
    weekly_plans(:one).check_ins.create!(day_of_week: 0, status: CheckIn::SKIPPED)

    duplicate = CheckIn.new(weekly_plan: weekly_plans(:one), day_of_week: 0, status: CheckIn::COMPLETED)
    assert_not duplicate.valid?

    # The same day in a different week is a different night.
    assert_predicate CheckIn.new(weekly_plan: weekly_plans(:two), day_of_week: 0, status: CheckIn::COMPLETED), :valid?
  end

  test "the one-per-night rule is enforced by the database, not only the validation" do
    weekly_plans(:one).check_ins.create!(day_of_week: 0, status: CheckIn::SKIPPED)

    assert_raises ActiveRecord::RecordNotUnique do
      CheckIn.insert_all!([
        { weekly_plan_id: weekly_plans(:one).weekly_plan_id, day_of_week: 0, status: CheckIn::COMPLETED }
      ])
    end
  end

  # Derived rather than stored: weekly_plans.start_date is the only place a week's dates live, and a
  # date column here would be a second one to disagree with it.
  test "knows the date it was for from its plan and its day index" do
    check_in = weekly_plans(:one).check_ins.create!(day_of_week: 3, status: CheckIn::COMPLETED)
    assert_equal Date.new(2026, 8, 20), check_in.date
  end

  test "is destroyed with its weekly plan" do
    plan = weekly_plans(:one)
    plan.check_ins.create!(day_of_week: 0, status: CheckIn::COMPLETED)

    assert_difference -> { CheckIn.count }, -1 do
      plan.destroy
    end
  end
end
