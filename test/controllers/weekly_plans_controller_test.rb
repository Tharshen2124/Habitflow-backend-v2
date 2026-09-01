require "test_helper"

class WeeklyPlansControllerTest < ActionDispatch::IntegrationTest
  test "without a token is unauthorized" do
    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}", as: :json
    assert_response :unauthorized
  end

  test "with a week_start that is not a Monday is unprocessable" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    get "/weekly-plans?week_start=2026-08-18", # a Tuesday
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :unprocessable_entity
  end

  test "returns a null plan for a week the user has not planned" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    get "/weekly-plans?week_start=2026-08-24",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_nil JSON.parse(response.body)["weekly_plan"]
  end

  test "looking at an unplanned week does not create a plan" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    assert_no_difference -> { WeeklyPlan.count } do
      get "/weekly-plans?week_start=2026-08-24",
        headers: { "Authorization" => "Bearer #{token}" }, as: :json
    end
  end

  test "returns the plan with its date range" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    plan = JSON.parse(response.body)["weekly_plan"]
    assert_equal weekly_plans(:one).weekly_plan_id, plan["weekly_plan_id"]
    assert_equal "2026-08-17", plan["start_date"]
    assert_equal "2026-08-23", plan["end_date"]
  end

  test "returns the week's fixed appointments" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    task = JSON.parse(response.body)["weekly_plan"]["tasks"].first
    assert_equal "Morning workout", task["title"]
    assert task["is_fixed_appointment"]
    assert_equal "06:00", task["start_time"]
    assert_equal "07:00", task["end_time"]
    assert_nil task["link_kind"]
  end

  test "describes a goal-linked task by its role and goal" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    user.tasks.create!(task_name: "Deep work", goal: goals(:one), day_of_week: 1,
                       start_time: "10:00", end_time: "11:00", weekly_plan: weekly_plans(:one))

    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    task = JSON.parse(response.body)["weekly_plan"]["tasks"].find { |t| t["title"] == "Deep work" }
    assert_equal "goal", task["link_kind"]
    assert_equal "Complete quarterly project milestone", task["link_text"]
    assert_equal "Professional", task["role_name"]
    assert_nil task["dimension"]
  end

  # The dashboard tints a task in the colour of the role behind it, and reads a week without ever
  # fetching its goals -- so the colour has to ride on the task, exactly as `is_weekly_priority` does.
  test "a goal-linked task reports its role's colour" do
    user = users(:one)
    roles(:one).update!(color_id: "teal")
    token = JsonWebToken.encode(user.to_token_payload)
    user.tasks.create!(task_name: "Deep work", goal: goals(:one), day_of_week: 1,
                       start_time: "10:00", end_time: "11:00", weekly_plan: weekly_plans(:one))

    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    task = JSON.parse(response.body)["weekly_plan"]["tasks"].find { |t| t["title"] == "Deep work" }
    assert_equal "teal", task["role_color_id"]
  end

  # The dashboard reads a week without ever fetching its goals, so the flag has to ride on the
  # task. It is the goal's, not the task's: `goals(:two)` is a weekly priority and `goals(:one)`
  # is not, and the two tasks below differ in nothing else.
  test "a goal-linked task reports whether its goal is a weekly priority" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    user.tasks.create!(task_name: "Ordinary", goal: goals(:one), day_of_week: 1,
                       start_time: "10:00", end_time: "11:00", weekly_plan: weekly_plans(:one))
    user.tasks.create!(task_name: "Priority work", goal: goals(:two), day_of_week: 1,
                       start_time: "11:00", end_time: "12:00", weekly_plan: weekly_plans(:one))

    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    by_title = JSON.parse(response.body)["weekly_plan"]["tasks"].index_by { |t| t["title"] }
    assert by_title["Priority work"]["is_weekly_priority"]
    assert_not by_title["Ordinary"]["is_weekly_priority"]
  end

  # No goal to inherit from, and a boolean rather than a null so the client never has to decide
  # what a missing one means.
  test "a task with no goal behind it is never a weekly priority" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    user.tasks.create!(task_name: "Morning run", sharpen_the_saw_activity: sharpen_the_saw_activities(:one),
                       day_of_week: 1, start_time: "07:00", end_time: "07:30", weekly_plan: weekly_plans(:one))

    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    by_title = JSON.parse(response.body)["weekly_plan"]["tasks"].index_by { |t| t["title"] }
    assert_equal false, by_title["Morning run"]["is_weekly_priority"]
    assert_equal false, by_title["Morning workout"]["is_weekly_priority"]
  end

  test "describes an activity-linked task by its dimension" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    user.tasks.create!(task_name: "Morning run", sharpen_the_saw_activity: sharpen_the_saw_activities(:one),
                       day_of_week: 1, start_time: "07:00", end_time: "07:30", weekly_plan: weekly_plans(:one))

    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    task = JSON.parse(response.body)["weekly_plan"]["tasks"].find { |t| t["title"] == "Morning run" }
    assert_equal "activity", task["link_kind"]
    assert_equal "Morning run", task["link_text"]
    assert_equal "physical", task["dimension"]
    assert_nil task["role_name"]
  end

  test "returns tasks in day then time order" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    user.tasks.create!(task_name: "Later on Monday", goal: goals(:one), day_of_week: 0,
                       start_time: "15:00", end_time: "16:00", weekly_plan: weekly_plans(:one))
    user.tasks.create!(task_name: "Tuesday", goal: goals(:one), day_of_week: 1,
                       start_time: "09:00", end_time: "10:00", weekly_plan: weekly_plans(:one))

    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    titles = JSON.parse(response.body)["weekly_plan"]["tasks"].map { |t| t["title"] }
    assert_equal [ "Morning workout", "Later on Monday", "Tuesday" ], titles
  end

  test "does not return another user's plan" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    plan = JSON.parse(response.body)["weekly_plan"]
    assert_equal weekly_plans(:one).weekly_plan_id, plan["weekly_plan_id"]
    assert_not_equal weekly_plans(:two).weekly_plan_id, plan["weekly_plan_id"]
    assert_equal [ "Morning workout" ], plan["tasks"].map { |t| t["title"] }
  end

  # ── this week's renewal activities ────────────────────────────────────────────────────────────
  #
  # The activity library is standing and belongs to the user; this join is only the statement
  # "these are the ones I am renewing with this week".

  def auth_for(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user.to_token_payload)}" }
  end

  test "sharpen-the-saw without a token is unauthorized" do
    get "/weekly-plans/sharpen-the-saw?week_start=#{FIXTURE_WEEK_START}", as: :json
    assert_response :unauthorized
  end

  test "sharpen-the-saw returns the activities committed to that week" do
    get "/weekly-plans/sharpen-the-saw?week_start=#{FIXTURE_WEEK_START}",
      headers: auth_for(users(:one)), as: :json

    assert_response :success
    assert_equal [ sharpen_the_saw_activities(:one).sharpen_the_saw_activity_id,
                   sharpen_the_saw_activities(:two).sharpen_the_saw_activity_id ].sort,
                 JSON.parse(response.body)["activity_ids"]
  end

  test "sharpen-the-saw answers empty for an unplanned week without creating one" do
    assert_no_difference -> { WeeklyPlan.count } do
      get "/weekly-plans/sharpen-the-saw?week_start=2026-08-24",
        headers: auth_for(users(:one)), as: :json
    end

    assert_response :success
    assert_empty JSON.parse(response.body)["activity_ids"]
  end

  test "updating sharpen-the-saw replaces the week's set" do
    keep = sharpen_the_saw_activities(:one).sharpen_the_saw_activity_id

    put "/weekly-plans/sharpen-the-saw",
      params: { week_start: FIXTURE_WEEK_START, activity_ids: [ keep ] },
      headers: auth_for(users(:one)), as: :json

    assert_response :success
    assert_equal [ keep ], JSON.parse(response.body)["activity_ids"]
    assert_equal [ keep ], weekly_plans(:one).weekly_plan_sts_activities.pluck(:sharpen_the_saw_activity_id)
  end

  # Having put an activity in the calendar is the stronger statement of the two. Dropping the join
  # row would leave the week contradicting its own schedule.
  test "updating sharpen-the-saw keeps an activity a task is already scheduled against" do
    scheduled = sharpen_the_saw_activities(:two)
    users(:one).tasks.create!(
      weekly_plan: weekly_plans(:one), sharpen_the_saw_activity: scheduled,
      task_name: "Read", is_fixed_appointment: false,
      day_of_week: 1, start_time: "20:00", end_time: "20:30"
    )

    put "/weekly-plans/sharpen-the-saw",
      params: { week_start: FIXTURE_WEEK_START, activity_ids: [] },
      headers: auth_for(users(:one)), as: :json

    assert_response :success
    assert_equal [ scheduled.sharpen_the_saw_activity_id ], JSON.parse(response.body)["activity_ids"]
  end

  test "updating sharpen-the-saw rejects an activity that is not the user's" do
    put "/weekly-plans/sharpen-the-saw",
      params: { week_start: FIXTURE_WEEK_START, activity_ids: [ sharpen_the_saw_activities(:one).sharpen_the_saw_activity_id ] },
      headers: auth_for(users(:two)), as: :json

    assert_response :unprocessable_entity
    assert_equal [ "Invalid sharpen the saw activity selected" ], JSON.parse(response.body)["errors"]
  end

  test "updating sharpen-the-saw rejects a soft-deleted activity" do
    put "/weekly-plans/sharpen-the-saw",
      params: { week_start: FIXTURE_WEEK_START, activity_ids: [ sharpen_the_saw_activities(:three).sharpen_the_saw_activity_id ] },
      headers: auth_for(users(:one)), as: :json

    assert_response :unprocessable_entity
  end

  # Choosing this week's activities is a write, so unlike the reads it does bring the plan into
  # existence -- that is the point at which the user has actually planned something.
  test "updating sharpen-the-saw creates the plan for an unplanned week" do
    assert_difference -> { WeeklyPlan.count }, 1 do
      put "/weekly-plans/sharpen-the-saw",
        params: { week_start: "2026-08-24", activity_ids: [ sharpen_the_saw_activities(:one).sharpen_the_saw_activity_id ] },
        headers: auth_for(users(:one)), as: :json
    end

    assert_response :success
  end

  test "updating sharpen-the-saw with a week_start that is not a Monday is unprocessable" do
    put "/weekly-plans/sharpen-the-saw",
      params: { week_start: "2026-08-18", activity_ids: [] },
      headers: auth_for(users(:one)), as: :json

    assert_response :unprocessable_entity
  end
end
