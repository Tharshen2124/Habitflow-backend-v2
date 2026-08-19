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

    assert_equal 1, user.roles.active.count
    assert_equal 2, user.roles.active.first.goals.count
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
                 user.roles.active.first.goals.pluck(:weekly_plan_id).uniq
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
    assert_equal [ plan.weekly_plan_id ], user.roles.active.first.goals.pluck(:weekly_plan_id).uniq
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

  # Re-submitting step 1 used to destroy every role the user had. It now archives the ones that
  # were dropped, so the rows -- and every past week that references them -- survive.
  test "create archives roles that are no longer submitted instead of destroying them" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    role = user.roles.create!(role_name: "Old Role")
    goal = role.goals.create!(description: "Old goal", weekly_plan: weekly_plans(:one))

    post "/onboarding/roles",
      params: {
        week_start: FIXTURE_WEEK_START,
        roles: [ { name: "New Role", icon_id: "home", goals: [ { text: "New goal" } ] } ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal [ "New Role" ], user.roles.active.pluck(:role_name)
    assert Role.exists?(role.role_id)
    assert_predicate role.reload, :archived?
    assert_predicate goal.reload, :dropped?
  end

  # An existing role that is submitted again is updated in place, so its id -- and everything
  # pointing at it -- stays stable across re-submits.
  test "create keeps the id of a role that is submitted again" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    role = roles(:one)

    post "/onboarding/roles",
      params: {
        week_start: FIXTURE_WEEK_START,
        roles: [ { name: "Professional", icon_id: "home", goals: [ { text: "Ship the thing" } ] } ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal [ role.role_id ], user.roles.active.pluck(:role_id)
    assert_equal "home", role.reload.icon_id
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

  # --- standing roles page -------------------------------------------------------------------

  test "index separates active roles from archived ones" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    retired = user.roles.create!(role_name: "Student", deleted_at: Time.current)

    get "/roles?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ "Professional" ], body["roles"].map { |r| r["name"] }
    assert_equal [ retired.role_id ], body["archived_roles"].map { |r| r["role_id"] }
  end

  test "create_role adds a single role with its colour" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    post "/roles",
      params: { week_start: FIXTURE_WEEK_START, role_name: "Athlete", icon_id: "dumbbell", color_id: "teal" },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :created
    role = Role.find(JSON.parse(response.body)["role"]["role_id"])
    assert_equal [ "Athlete", "dumbbell", "teal" ], [ role.role_name, role.icon_id, role.color_id ]
    assert_empty JSON.parse(response.body)["role"]["goals"]
  end

  test "update_role renames a role without disturbing its goals" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    patch "/roles/#{roles(:one).role_id}",
      params: { week_start: FIXTURE_WEEK_START, role_name: "Engineer", color_id: "rose" },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_equal "Engineer", roles(:one).reload.role_name
    assert_equal 2, roles(:one).goals.active.count
  end

  # The dialog states real numbers before the user commits, so the preview has to agree with what
  # the destroy then actually does.
  test "archive-preview counts this week's goals and splits their tasks" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    user.tasks.create!(weekly_plan: weekly_plans(:one), goal: goals(:one), task_name: "Done",
                       is_completed: true, day_of_week: 1, start_time: "09:00", end_time: "10:00")
    user.tasks.create!(weekly_plan: weekly_plans(:one), goal: goals(:two), task_name: "Not done",
                       day_of_week: 2, start_time: "09:00", end_time: "10:00")

    get "/roles/#{roles(:one).role_id}/archive-preview?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_equal({ "goals" => 2, "incomplete_tasks" => 1, "completed_tasks" => 1 },
                 JSON.parse(response.body)["preview"])
  end

  test "destroy_role archives the role and this week's goals, keeping completed tasks" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    done = user.tasks.create!(weekly_plan: weekly_plans(:one), goal: goals(:one), task_name: "Done",
                              is_completed: true, day_of_week: 1, start_time: "09:00", end_time: "10:00")
    pending_task = user.tasks.create!(weekly_plan: weekly_plans(:one), goal: goals(:two), task_name: "Not done",
                                      day_of_week: 2, start_time: "09:00", end_time: "10:00")

    delete "/roles/#{roles(:one).role_id}",
      params: { week_start: FIXTURE_WEEK_START },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_equal({ "goals" => 2, "incomplete_tasks" => 1, "completed_tasks" => 1 },
                 JSON.parse(response.body)["archived"])

    assert_predicate roles(:one).reload, :archived?
    assert Role.exists?(roles(:one).role_id)
    assert_equal 0, roles(:one).goals.active.count
    assert Task.exists?(done.task_id)
    assert_not Task.exists?(pending_task.task_id)
  end

  test "an archived role is not found for update" do
    token = JsonWebToken.encode(users(:one).to_token_payload)
    roles(:one).update!(deleted_at: Time.current)

    patch "/roles/#{roles(:one).role_id}",
      params: { week_start: FIXTURE_WEEK_START, role_name: "Engineer" },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :not_found
  end

  test "restore_role brings a role back for future planning" do
    token = JsonWebToken.encode(users(:one).to_token_payload)
    roles(:one).update!(deleted_at: Time.current)

    post "/roles/#{roles(:one).role_id}/restore",
      params: { week_start: FIXTURE_WEEK_START },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_not_predicate roles(:one).reload, :archived?
  end

  test "destroy_role does not touch another user's role" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    delete "/roles/#{roles(:two).role_id}",
      params: { week_start: FIXTURE_WEEK_START },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :not_found
    assert_not_predicate roles(:two).reload, :archived?
  end

  # The reason roles archive instead of deleting: /history and /analytics resolve a task's role
  # through goal -> role, so a past week has to keep reporting one long after it is retired.
  test "a past week still reports its role name after the role is archived" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    user.tasks.create!(weekly_plan: weekly_plans(:one), goal: goals(:one), task_name: "Wrote the report",
                       is_completed: true, day_of_week: 1, start_time: "09:00", end_time: "10:00")

    # Retire the role while planning a later week; the earlier week is not the one being edited.
    delete "/roles/#{roles(:one).role_id}",
      params: { week_start: "2026-08-24" },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json
    assert_response :success

    get "/weekly-plans?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_not_predicate goals(:one).reload, :dropped?, "an earlier week's goals are left alone"

    task = JSON.parse(response.body)["weekly_plan"]["tasks"].find { |t| t["title"] == "Wrote the report" }
    assert_equal "Professional", task["role_name"]
    assert_equal "goal", task["link_kind"]
    assert_equal "Complete quarterly project milestone", task["link_text"]
  end
end
