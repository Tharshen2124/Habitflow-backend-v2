require "test_helper"

class AnalyticsControllerTest < ActionDispatch::IntegrationTest
  PAST_WEEK = "2026-08-10".freeze
  # Wide enough to reach past_week and short enough to stay inside the 52-week cap.
  RANGE = "from=2026-07-06&to=2026-08-17".freeze

  # The page is a paid feature, and every test below is about the figures it returns rather than
  # about who may see them. The gate itself is asserted on its own, at the end of the file.
  setup { premium!(users(:one), users(:three), users(:four)) }

  def token_for(user)
    JsonWebToken.encode(user.to_token_payload)
  end

  def auth(user)
    { "Authorization" => "Bearer #{token_for(user)}" }
  end

  def weeks_for(user, query = RANGE)
    get "/analytics?#{query}", headers: auth(user), as: :json
    JSON.parse(response.body)["weeks"]
  end

  def past_week
    weeks_for(users(:three)).find { |w| w["week_start"] == PAST_WEEK }
  end

  # --- the range guard -------------------------------------------------------------------------

  test "without a token is unauthorized" do
    get "/analytics?#{RANGE}", as: :json
    assert_response :unauthorized
  end

  test "rejects a bound that is not a Monday" do
    get "/analytics?from=2026-07-07&to=#{PAST_WEEK}", headers: auth(users(:three)), as: :json
    assert_response :unprocessable_entity
  end

  test "rejects a range that runs backwards" do
    get "/analytics?from=2026-08-17&to=2026-07-06", headers: auth(users(:three)), as: :json
    assert_response :unprocessable_entity
  end

  test "rejects a range longer than 52 weeks" do
    get "/analytics?from=2024-08-12&to=2026-08-17", headers: auth(users(:three)), as: :json
    assert_response :unprocessable_entity
  end

  test "reading analytics does not plan any of the weeks it looked at" do
    assert_no_difference -> { WeeklyPlan.count } do
      get "/analytics?#{RANGE}", headers: auth(users(:three)), as: :json
    end

    assert_response :success
  end

  # --- what comes back -------------------------------------------------------------------------

  test "a week with no plan is absent rather than zero-filled" do
    weeks = weeks_for(users(:three))

    assert_equal [ PAST_WEEK ], weeks.map { |w| w["week_start"] }
    assert_equal "2026-08-16", weeks.first["end_date"]
  end

  test "returns nothing for a range the user never planned" do
    assert_equal [], weeks_for(users(:three), "from=2026-01-05&to=2026-03-02")
  end

  test "is scoped to the requesting user" do
    assert_equal [ FIXTURE_WEEK_START ], weeks_for(users(:one)).map { |w| w["week_start"] }
  end

  test "weeks come back most recent first" do
    weeks = weeks_for(users(:four))

    assert_equal [ "2026-08-17", "2026-08-10", "2026-08-03", "2026-07-27" ],
                 weeks.map { |w| w["week_start"] }
  end

  # --- goals -----------------------------------------------------------------------------------

  test "counts active goals only, and reports the dropped one beside the ratio" do
    # Three active goals -- the dropped one is out of the denominator so pruning cannot raise the
    # rate -- of which one had every task done. The goal on the archived role has no task scheduled
    # against it at all, and `Goal.achieved` is deliberately not vacuous: nothing to do is not the
    # same as everything done.
    assert_equal({ "achieved" => 1, "total" => 3, "dropped" => 1 }, past_week["goals"])
  end

  # --- roles -----------------------------------------------------------------------------------

  test "counts tasks per role through the goal they serve" do
    roles = past_week["roles"]

    assert_equal 1, roles.size
    programmer = roles.first
    assert_equal "Programmer", programmer["name"]
    assert_equal "primary", programmer["color_id"]
    assert_equal roles(:standing).role_id, programmer["role_id"]
    # Two goal-linked tasks, one of them done. The fixed appointment carries no goal, so it cannot
    # reach a role and is absent rather than counted against one.
    assert_equal 2, programmer["total"]
    assert_equal 1, programmer["completed"]
  end

  test "a week planned under a role since archived still reports under that role" do
    # Created here rather than as a fixture: the past week's task counts are asserted by
    # history_controller_test, and a shared fixture would move them.
    Task.create!(
      user: users(:three),
      weekly_plan: weekly_plans(:past),
      goal: goals(:past_archived_role),
      task_name: "Run the Saturday session",
      is_completed: true,
      day_of_week: 5,
      start_time: "10:00",
      end_time: "12:00"
    )

    volunteer = past_week["roles"].find { |r| r["name"] == "Volunteer" }

    assert volunteer, "an archived role still owned the tasks it owned"
    assert_equal "teal", volunteer["color_id"]
    assert_equal 1, volunteer["total"]
    assert_equal 1, volunteer["completed"]
  end

  # --- sharpen the saw -------------------------------------------------------------------------

  test "scores a dimension by how many of its scheduled tasks were completed" do
    dimensions = past_week["dimensions"]

    assert_equal 1, dimensions.size
    physical = dimensions.first
    assert_equal "physical", physical["dimension"], "the raw stored string, not a display name"
    assert_equal 1, physical["total"]
    assert_equal 1, physical["completed"]
  end

  test "omits a dimension the week scheduled nothing for, rather than sending a zero" do
    # The week committed to a social activity but never scheduled a task against it. The client
    # holds the four fixed dimensions and fills the gap itself.
    assert_equal [], past_week["dimensions"].select { |d| d["dimension"] == "social" }
  end

  # --- daily priorities ------------------------------------------------------------------------

  test "counts starred priorities per day, and omits the days without one" do
    priorities = past_week["daily_priorities"]

    assert_equal [ { "day_of_week" => 3, "completed" => 0, "total" => 1 } ], priorities
  end

  test "a fixed appointment reaches none of the four figures" do
    week = past_week

    assert_equal 3, week["roles"].sum { |r| r["total"] } + week["dimensions"].sum { |d| d["total"] },
                 "the week's four tasks less the fixed appointment"
    assert_empty week["daily_priorities"].select { |d| d["day_of_week"] == tasks(:past_fixed).day_of_week }
  end

  # --- the premium gate ------------------------------------------------------------------------

  test "a free account is refused the whole page" do
    users(:three).update!(subscription_status: nil, subscription_period_end: nil)

    get "/analytics?#{RANGE}", headers: auth(users(:three)), as: :json

    assert_response :payment_required
    assert_equal [ "This is a Premium feature" ], JSON.parse(response.body)["errors"]
  end

  # 402 rather than 403, so the client can tell "you have not paid for this" from the one 403 this
  # app already answers, which means something else entirely -- a session belonging to someone else.
  test "the refusal is distinguishable from an unauthorized one" do
    users(:three).update!(subscription_status: nil, subscription_period_end: nil)

    get "/analytics?#{RANGE}", headers: auth(users(:three)), as: :json
    assert_equal 402, response.status

    get "/analytics?#{RANGE}", as: :json
    assert_equal 401, response.status
  end

  test "an account whose paid period has run out is refused" do
    users(:three).update!(subscription_status: "active", subscription_period_end: 1.day.ago)

    get "/analytics?#{RANGE}", headers: auth(users(:three)), as: :json

    assert_response :payment_required
  end

  # The gate is declared before the range is parsed, so a free account is turned away without the
  # endpoint saying anything about what it would have found.
  test "a free account is refused even with a range it could never read" do
    users(:three).update!(subscription_status: nil, subscription_period_end: nil)

    get "/analytics?from=2026-08-17&to=2026-07-06", headers: auth(users(:three)), as: :json

    assert_response :payment_required
  end
end
