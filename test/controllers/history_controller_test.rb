require "test_helper"

class HistoryControllerTest < ActionDispatch::IntegrationTest
  PAST_WEEK = "2026-08-10".freeze

  def token_for(user)
    JsonWebToken.encode(user.to_token_payload)
  end

  def auth(user)
    { "Authorization" => "Bearer #{token_for(user)}" }
  end

  def goal_named(text)
    JSON.parse(response.body)["week"]["goals"].find { |g| g["text"] == text }
  end

  # --- GET /history --------------------------------------------------------------------------

  test "without a token is unauthorized" do
    get "/history?week_start=#{PAST_WEEK}", as: :json
    assert_response :unauthorized
  end

  test "with a week_start that is not a Monday is unprocessable" do
    get "/history?week_start=2026-08-11", headers: auth(users(:three)), as: :json
    assert_response :unprocessable_entity
  end

  test "returns a null week for one the user never planned, and does not create it" do
    assert_no_difference -> { WeeklyPlan.count } do
      get "/history?week_start=2026-07-06", headers: auth(users(:three)), as: :json
    end

    assert_response :success
    assert_nil JSON.parse(response.body)["week"]
  end

  test "a week belonging to another user is not visible" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:one)), as: :json

    assert_response :success
    assert_nil JSON.parse(response.body)["week"]
  end

  test "returns the week's goals including the dropped one" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:three)), as: :json
    assert_response :success

    goals = JSON.parse(response.body)["week"]["goals"]
    dropped = goals.find { |g| g["goal_id"] == goals(:past_dropped).goal_id }

    # The planning reads filter this row out; /history is the surface that must not.
    assert_not_nil dropped
    assert dropped["is_dropped"]
    assert_not goals.find { |g| g["goal_id"] == goals(:past_achieved).goal_id }["is_dropped"]
  end

  test "keeps a goal whose role has since been archived" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:three)), as: :json

    goals = JSON.parse(response.body)["week"]["goals"]
    carried = goals.find { |g| g["goal_id"] == goals(:past_archived_role).goal_id }

    assert_not_nil carried, "an archived role's goal must survive in the week it was planned in"
    assert carried["role"]["is_archived"]
    assert_equal "Volunteer", carried["role"]["name"]
    assert_equal "teal", carried["role"]["color_id"]
  end

  test "reports outcome as parts, leaving the four-way split to the client" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:three)), as: :json

    goal = JSON.parse(response.body)["week"]["goals"].first

    # Whether a week has ended is a client fact, so no `outcome` is sent -- only what it is made of.
    assert_not goal.key?("outcome")
    assert goal.key?("is_achieved")
    assert goal.key?("is_dropped")
    # Carrying forward is reported beside the outcome, never as one: a goal can be carried out of a
    # week it was achieved in, and the client draws both.
    assert goal.key?("is_carried_forward")
  end

  test "is_achieved is read off the goal's tasks, not off the stored column" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:three)), as: :json

    goals = JSON.parse(response.body)["week"]["goals"]

    assert goals.find { |g| g["goal_id"] == goals(:past_achieved).goal_id }["is_achieved"],
           "its one task was completed"
    assert_not goals.find { |g| g["goal_id"] == goals(:past_missed).goal_id }["is_achieved"],
               "its one task was not"
    assert_not goals.find { |g| g["goal_id"] == goals(:past_archived_role).goal_id }["is_achieved"],
               "a goal with nothing scheduled was not achieved by having nothing to do"
  end

  test "a goal carried in reports how many weeks it has been running" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:four)), as: :json
    assert_response :success

    goal = goal_named("Finish the literature review")
    # Begun two weeks earlier and carried twice, so the third week is its third.
    assert_equal 3, goal["week_index"]
    # And it did not stop there -- which is what separates it from a goal simply left unfinished.
    assert goal["is_carried_forward"]
  end

  test "a goal begun in the week itself is on its first, and points nowhere" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:four)), as: :json

    goal = goal_named("Book the lab session")
    assert_equal 1, goal["week_index"]
    assert_not goal["is_carried_forward"]
  end

  test "a user with no carryovers at all reports every goal as a first week" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:three)), as: :json

    goals = JSON.parse(response.body)["week"]["goals"]
    assert_equal [ 1 ], goals.map { |g| g["week_index"] }.uniq
    assert_empty goals.select { |g| g["is_carried_forward"] }
  end

  test "keeps an activity the user has deleted since, flagged rather than hidden" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:three)), as: :json

    activities = JSON.parse(response.body)["week"]["activities"]
    deleted = activities.find do |a|
      a["sharpen_the_saw_activity_id"] == sharpen_the_saw_activities(:past_deleted).sharpen_the_saw_activity_id
    end

    assert_equal 2, activities.size
    assert_not_nil deleted
    assert deleted["is_deleted"]
    assert_equal "social", deleted["dimension"]
    assert_equal "Call home on Sundays", deleted["activity_description"]
  end

  test "each task carries what it was for, so the schedule can name its category" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:three)), as: :json

    tasks = JSON.parse(response.body)["week"]["tasks"]
    by_title = tasks.index_by { |t| t["title"] }

    goal_task = by_title["Draft chapter 3"]
    assert_equal "goal", goal_task["link_kind"]
    assert_equal "Ship the FYP", goal_task["link_text"]
    assert_equal "Programmer", goal_task["role_name"]
    assert_equal "primary", goal_task["role_color_id"]
    assert_nil goal_task["dimension"]
    assert goal_task["is_completed"]

    activity_task = by_title["Swim"]
    assert_equal "activity", activity_task["link_kind"]
    assert_equal "physical", activity_task["dimension"]
    assert_nil activity_task["role_name"]

    fixed = by_title["Team standup"]
    assert fixed["is_fixed_appointment"]
    assert_nil fixed["link_kind"]
  end

  # The two priorities are separate facts and a schedule draws them differently -- a weekly
  # priority takes the reserved yellow, a daily one takes a star. Reading either off the other
  # would have been wrong for `past_goal_missed`, which is a daily priority under a goal that is
  # not a weekly one.
  test "a task reports the weekly priority of the goal it served, not its own daily flag" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:three)), as: :json

    by_title = JSON.parse(response.body)["week"]["tasks"].index_by { |t| t["title"] }

    assert by_title["Draft chapter 3"]["is_weekly_priority"]
    assert_not by_title["Draft chapter 3"]["is_daily_priority"]

    assert_not by_title["Outline the evaluation"]["is_weekly_priority"]
    assert by_title["Outline the evaluation"]["is_daily_priority"]
  end

  # Neither has a goal to inherit from, and the field is a boolean rather than a null so the client
  # never has to decide what a missing one means.
  test "a task with no goal behind it is never a weekly priority" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:three)), as: :json

    by_title = JSON.parse(response.body)["week"]["tasks"].index_by { |t| t["title"] }

    assert_equal false, by_title["Swim"]["is_weekly_priority"]
    assert_equal false, by_title["Team standup"]["is_weekly_priority"]
  end

  test "tasks come back ordered by day then start time" do
    get "/history?week_start=#{PAST_WEEK}", headers: auth(users(:three)), as: :json

    tasks = JSON.parse(response.body)["week"]["tasks"]
    assert_equal tasks.map { |t| [ t["day_of_week"], t["start_time"] ] }.sort,
                 tasks.map { |t| [ t["day_of_week"], t["start_time"] ] }
  end

  # --- GET /history/weeks --------------------------------------------------------------------

  test "the week strip is unauthorized without a token" do
    get "/history/weeks?from=#{PAST_WEEK}&to=#{PAST_WEEK}", as: :json
    assert_response :unauthorized
  end

  test "the week strip rejects a bound that is not a Monday" do
    get "/history/weeks?from=2026-08-11&to=#{PAST_WEEK}", headers: auth(users(:three)), as: :json
    assert_response :unprocessable_entity
  end

  test "the week strip rejects a backwards range" do
    get "/history/weeks?from=2026-08-17&to=#{PAST_WEEK}", headers: auth(users(:three)), as: :json
    assert_response :unprocessable_entity
  end

  test "the week strip rejects a range longer than 52 weeks" do
    get "/history/weeks?from=2025-08-04&to=2026-08-17", headers: auth(users(:three)), as: :json
    assert_response :unprocessable_entity
  end

  test "the week strip counts what each week held" do
    get "/history/weeks?from=2026-07-06&to=2026-08-17", headers: auth(users(:three)), as: :json
    assert_response :success

    weeks = JSON.parse(response.body)["weeks"]
    assert_equal 1, weeks.size, "a week with no plan is absent, not zero-filled"

    week = weeks.first
    assert_equal PAST_WEEK, week["week_start"]
    # Three active goals: the dropped one is out of the denominator so pruning cannot raise the rate.
    assert_equal 3, week["goal_count"]
    # One: past_achieved, whose only task was done. past_archived_role has no task scheduled at all,
    # which is not the same as having finished everything.
    assert_equal 1, week["goals_achieved"]
    # Scheduled tasks only -- the fixed appointment is counted on its own tile.
    assert_equal 3, week["task_count"]
    assert_equal 2, week["tasks_completed"]
    assert_equal 2, week["activity_count"]
  end

  test "the week strip is scoped to the requesting user" do
    get "/history/weeks?from=2026-07-06&to=2026-08-17", headers: auth(users(:two)), as: :json

    weeks = JSON.parse(response.body)["weeks"]
    assert_equal [ FIXTURE_WEEK_START ], weeks.map { |w| w["week_start"] }
  end

  test "the week strip returns most recent first" do
    WeeklyPlan.create!(user_id: users(:three).user_id, start_date: Date.new(2026, 8, 3))

    get "/history/weeks?from=2026-07-06&to=2026-08-17", headers: auth(users(:three)), as: :json

    assert_equal [ PAST_WEEK, "2026-08-03" ], JSON.parse(response.body)["weeks"].map { |w| w["week_start"] }
  end
end
