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
end
