require "test_helper"

class RolesControllerTest < ActionDispatch::IntegrationTest
  test "index without a token is unauthorized" do
    get "/onboarding/roles?week_start=#{FIXTURE_WEEK_START}", as: :json
    assert_response :unauthorized
  end

  test "index returns the current user's roles with nested goals" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    get "/onboarding/roles?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["roles"].size
    assert_equal "Professional", body["roles"].first["name"]
    assert_equal 2, body["roles"].first["goals"].size
  end

  test "index does not return another user's roles" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    get "/onboarding/roles?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    body = JSON.parse(response.body)
    assert_not_includes body["roles"].map { |r| r["name"] }, "Parent"
  end

  test "index without a week_start is unprocessable" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    get "/onboarding/roles", headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :unprocessable_entity
  end

  test "index with a week_start that is not a Monday is unprocessable" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    get "/onboarding/roles?week_start=2026-08-18", # a Tuesday
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :unprocessable_entity
  end

  test "index returns a role carried into a new week with no goals yet" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    get "/onboarding/roles?week_start=2026-08-24",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Professional", body["roles"].first["name"]
    assert_empty body["roles"].first["goals"]
  end

  test "create without a token is unauthorized" do
    post "/onboarding/roles", params: { week_start: FIXTURE_WEEK_START, roles: [] }, as: :json
    assert_response :unauthorized
  end

  test "create persists roles and their nested goals scoped to current_user" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/roles",
      params: {
        week_start: FIXTURE_WEEK_START,
        roles: [
          {
            name: "Athlete",
            icon_id: "dumbbell",
            goals: [
              { text: "Run a 10k", is_weekly_priority: true },
              { text: "Stretch daily" }
            ]
          }
        ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal 1, body["roles"].size
    assert_equal "Athlete", body["roles"].first["name"]
    assert_equal 2, body["roles"].first["goals"].size

    assert_equal 1, user.roles.count
    assert_equal 2, user.roles.first.goals.count
  end

  test "create stamps the created goals with the plan for the submitted week" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/roles",
      params: {
        week_start: FIXTURE_WEEK_START,
        roles: [ { name: "Athlete", icon_id: "dumbbell", goals: [ { text: "Run a 10k" } ] } ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal [ weekly_plans(:one).weekly_plan_id ],
                 user.roles.first.goals.pluck(:weekly_plan_id).uniq
  end

  test "create builds the weekly plan when the user has none for that week" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    assert_difference -> { user.weekly_plans.count }, 1 do
      post "/onboarding/roles",
        params: {
          week_start: "2026-08-24",
          roles: [ { name: "Athlete", icon_id: "dumbbell", goals: [ { text: "Run a 10k" } ] } ]
        },
        headers: { "Authorization" => "Bearer #{token}" },
        as: :json
    end

    assert_response :created
    plan = user.weekly_plans.find_by(start_date: Date.new(2026, 8, 24))
    assert_equal Date.new(2026, 8, 30), plan.end_date
    assert_equal [ plan.weekly_plan_id ], user.roles.first.goals.pluck(:weekly_plan_id).uniq
  end

  test "create with a week_start that is not a Monday is unprocessable" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    post "/onboarding/roles",
      params: { week_start: "2026-08-18", roles: [] },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"].first, "Monday"
  end

  test "create replaces the user's existing roles instead of duplicating them" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    role = user.roles.create!(role_name: "Old Role")
    role.goals.create!(description: "Old goal", weekly_plan: weekly_plans(:one))

    post "/onboarding/roles",
      params: {
        week_start: FIXTURE_WEEK_START,
        roles: [ { name: "New Role", icon_id: "home", goals: [ { text: "New goal" } ] } ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal 1, user.roles.count
    assert_equal "New Role", user.roles.first.role_name
    assert_not Role.exists?(role.role_id)
  end

  test "create does not touch another user's roles" do
    user = users(:one)
    other_user = users(:two)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/roles",
      params: { week_start: FIXTURE_WEEK_START, roles: [ { name: "Mine", icon_id: "home", goals: [] } ] },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal 1, other_user.reload.roles.count
  end
end
