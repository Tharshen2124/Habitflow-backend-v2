require "test_helper"

class CheckInsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @plan = weekly_plans(:one)
  end

  def auth(user = @user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user.to_token_payload)}" }
  end

  def check_in(day_of_week:, status:, week_start: FIXTURE_WEEK_START, headers: auth)
    put "/weekly-plans/check-in",
      params: { week_start: week_start, day_of_week: day_of_week, status: status },
      headers: headers, as: :json
  end

  test "without a token is unauthorized" do
    put "/weekly-plans/check-in",
      params: { week_start: FIXTURE_WEEK_START, day_of_week: 0, status: "completed" }, as: :json
    assert_response :unauthorized
  end

  test "with a week_start that is not a Monday is unprocessable" do
    check_in(day_of_week: 0, status: "completed", week_start: "2026-08-18")
    assert_response :unprocessable_entity
  end

  test "records a completed check-in" do
    check_in(day_of_week: 2, status: "completed")
    assert_response :success

    body = JSON.parse(response.body)["check_in"]
    assert_equal 2, body["day_of_week"]
    assert_equal "completed", body["status"]
  end

  test "records a skip, which is the fact nothing else in the schema holds" do
    check_in(day_of_week: 2, status: "skipped")

    assert_equal "skipped", JSON.parse(response.body).dig("check_in", "status")
    # The reflection is what a completed check-in leaves behind, so a skip must leave none.
    assert_nil @plan.evening_reflections.find_by(day_of_week: 2)
  end

  # A night dismissed at nine and saved at eleven is one night, not two.
  test "a second check-in for the same night updates the first rather than adding a row" do
    check_in(day_of_week: 3, status: "skipped")

    assert_no_difference -> { CheckIn.count } do
      check_in(day_of_week: 3, status: "completed")
    end

    assert_equal "completed", @plan.check_ins.find_by(day_of_week: 3).status
  end

  # Only a stale client can ask for this -- the prompt is suppressed once a check-in exists -- and
  # losing the record of a completed night to one would be the worse outcome.
  test "a completed night is not downgraded by a later skip" do
    check_in(day_of_week: 3, status: "completed")
    check_in(day_of_week: 3, status: "skipped")

    assert_response :success
    assert_equal "completed", @plan.check_ins.find_by(day_of_week: 3).status
  end

  test "a status outside the two the model knows is unprocessable" do
    check_in(day_of_week: 3, status: "postponed")

    assert_response :unprocessable_entity
    assert_match(/Status/, JSON.parse(response.body)["errors"].join)
  end

  test "a day outside the week is unprocessable" do
    check_in(day_of_week: 7, status: "completed")

    assert_response :unprocessable_entity
    assert_match(/Day of week/, JSON.parse(response.body)["errors"].join)
  end

  # A check-in belongs to a plan, so there is nowhere to put one for a week that was never planned.
  test "an unplanned week is refused and is not brought into existence by checking in" do
    assert_no_difference -> { WeeklyPlan.count } do
      check_in(day_of_week: 0, status: "completed", week_start: "2026-08-24")
    end

    assert_response :unprocessable_entity
    assert_match(/Plan this week/, JSON.parse(response.body)["errors"].join)
  end

  test "checks in to the caller's own week, never another user's" do
    check_in(day_of_week: 4, status: "completed", headers: auth(users(:two)))

    assert_response :success
    assert_nil @plan.check_ins.find_by(day_of_week: 4)
    assert_equal "completed", weekly_plans(:two).check_ins.find_by(day_of_week: 4).status
  end

  # ── how the dashboard reads them back ────────────────────────────────────────

  test "the weekly plan carries the week's check-ins in day order" do
    check_in(day_of_week: 4, status: "skipped")
    check_in(day_of_week: 1, status: "completed")

    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}", headers: auth, as: :json

    check_ins = JSON.parse(response.body)["weekly_plan"]["check_ins"]
    assert_equal [ 1, 4 ], check_ins.map { |c| c["day_of_week"] }
    assert_equal [ "completed", "skipped" ], check_ins.map { |c| c["status"] }
  end

  # The dashboard needs the time and the week together to decide whether to prompt, so the time
  # rides along even when there is no plan to prompt about.
  test "the weekly plan carries the check-in time, planned or not" do
    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}", headers: auth, as: :json
    assert_equal "21:00", JSON.parse(response.body)["eod_time"]

    get "/weekly-plans?week_start=2026-08-24", headers: auth, as: :json
    body = JSON.parse(response.body)
    assert_nil body["weekly_plan"]
    assert_equal "21:00", body["eod_time"]
  end
end
