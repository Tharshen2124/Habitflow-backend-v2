require "test_helper"

class GoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @token = JsonWebToken.encode(@user.to_token_payload)
  end

  def auth
    { "Authorization" => "Bearer #{@token}" }
  end

  def task_for(goal, name:, completed:, day:)
    @user.tasks.create!(
      weekly_plan: goal.weekly_plan, goal: goal, task_name: name, is_completed: completed,
      day_of_week: day, start_time: "09:00", end_time: "10:00"
    )
  end

  test "create without a token is unauthorized" do
    post "/goals", params: { week_start: FIXTURE_WEEK_START, role_id: roles(:one).role_id, description: "x" }, as: :json
    assert_response :unauthorized
  end

  test "create adds a goal to the requested week" do
    post "/goals",
      params: { week_start: FIXTURE_WEEK_START, role_id: roles(:one).role_id, description: "Ship the thing" },
      headers: auth, as: :json

    assert_response :created
    goal = Goal.find(JSON.parse(response.body)["goal"]["goal_id"])
    assert_equal weekly_plans(:one).weekly_plan_id, goal.weekly_plan_id
    assert_equal roles(:one).role_id, goal.role_id
  end

  test "create against another user's role is not found" do
    post "/goals",
      params: { week_start: FIXTURE_WEEK_START, role_id: roles(:two).role_id, description: "Nope" },
      headers: auth, as: :json

    assert_response :not_found
  end

  test "update marks a goal completed" do
    patch "/goals/#{goals(:one).goal_id}",
      params: { week_start: FIXTURE_WEEK_START, is_completed: true }, headers: auth, as: :json

    assert_response :success
    assert_predicate goals(:one).reload, :is_completed
  end

  # The rule the whole soft-delete model exists for: what was actually done that week survives
  # dropping the goal it was done under, so the numbers can't be improved by deleting things.
  test "destroy keeps the goal row and its completed tasks, and clears the unfinished ones" do
    goal = goals(:one)
    done = task_for(goal, name: "Wrote the report", completed: true, day: 1)
    pending_task = task_for(goal, name: "Review the draft", completed: false, day: 2)

    delete "/goals/#{goal.goal_id}", params: { week_start: FIXTURE_WEEK_START }, headers: auth, as: :json

    assert_response :success
    assert_equal({ "goals" => 1, "incomplete_tasks" => 1, "completed_tasks" => 1 },
                 JSON.parse(response.body)["archived"])

    assert_predicate goal.reload, :dropped?
    assert Task.exists?(done.task_id)
    assert_equal goal.goal_id, done.reload.goal_id, "a completed task keeps its link to the role"
    assert_not Task.exists?(pending_task.task_id)
  end

  test "destroy twice is not found the second time" do
    delete "/goals/#{goals(:one).goal_id}", params: { week_start: FIXTURE_WEEK_START }, headers: auth, as: :json
    assert_response :success

    delete "/goals/#{goals(:one).goal_id}", params: { week_start: FIXTURE_WEEK_START }, headers: auth, as: :json
    assert_response :not_found
  end

  test "destroy does not touch another user's goal" do
    delete "/goals/#{goals(:three).goal_id}", params: { week_start: FIXTURE_WEEK_START }, headers: auth, as: :json

    assert_response :not_found
    assert_not_predicate goals(:three).reload, :dropped?
  end

  test "restore brings back a goal dropped in the same week" do
    goals(:one).update!(deleted_at: Time.current)

    post "/goals/#{goals(:one).goal_id}/restore",
      params: { week_start: FIXTURE_WEEK_START }, headers: auth, as: :json

    assert_response :success
    assert_not_predicate goals(:one).reload, :dropped?
  end

  # Undo is for the mistake you just made. Reviving a goal dropped weeks ago would rewrite that
  # week's outcome from "dropped" back to "missed".
  test "restore refuses a goal that belongs to a different week" do
    goals(:one).update!(deleted_at: Time.current)

    post "/goals/#{goals(:one).goal_id}/restore",
      params: { week_start: "2026-08-24" }, headers: auth, as: :json

    assert_response :unprocessable_entity
    assert_predicate goals(:one).reload, :dropped?
  end

  test "carry-forward candidates lists last week's live goals" do
    get "/goals/carry-forward-candidates?week_start=2026-08-24", headers: auth, as: :json

    assert_response :success
    candidates = JSON.parse(response.body)["candidates"]
    assert_equal [ "Complete quarterly project milestone", "Mentor junior team member" ],
                 candidates.map { |c| c["text"] }.sort
    assert_equal [ "Professional" ], candidates.map { |c| c["role_name"] }.uniq
  end

  test "carry-forward candidates excludes goals of an archived role" do
    roles(:one).update!(deleted_at: Time.current)

    get "/goals/carry-forward-candidates?week_start=2026-08-24", headers: auth, as: :json

    assert_response :success
    assert_empty JSON.parse(response.body)["candidates"]
  end

  test "carry-forward candidates excludes a goal that was already carried" do
    post "/goals/carry-forward",
      params: { week_start: "2026-08-24", goal_ids: [ goals(:one).goal_id ] }, headers: auth, as: :json
    assert_response :created

    get "/goals/carry-forward-candidates?week_start=2026-08-24", headers: auth, as: :json

    assert_equal [ "Mentor junior team member" ],
                 JSON.parse(response.body)["candidates"].map { |c| c["text"] }
  end

  test "carry-forward copies the goal into the new week and records the link" do
    assert_difference "GoalCarryover.count", 1 do
      post "/goals/carry-forward",
        params: { week_start: "2026-08-24", goal_ids: [ goals(:one).goal_id ] }, headers: auth, as: :json
    end

    assert_response :created
    destination = Goal.find(JSON.parse(response.body)["goals"].first["goal_id"])
    assert_equal "Complete quarterly project milestone", destination.description
    assert_equal roles(:one).role_id, destination.role_id
    assert_equal Date.new(2026, 8, 24), destination.weekly_plan.start_date
    assert_equal goals(:one), destination.carried_from.source_goal
    # The original stays exactly where it was.
    assert_equal weekly_plans(:one).weekly_plan_id, goals(:one).reload.weekly_plan_id
  end

  test "listing carry-forward candidates does not create a plan" do
    assert_no_difference -> { WeeklyPlan.count } do
      get "/goals/carry-forward-candidates?week_start=2026-08-24", headers: auth, as: :json
    end

    assert_response :success
  end

  # Someone coming back after a gap has nothing at week_start - 7. Looking back only one week told
  # them they had never set a goal in their life.
  test "carry-forward candidates reach back past a gap to the last week actually planned" do
    get "/goals/carry-forward-candidates?week_start=2026-09-14", headers: auth, as: :json

    assert_response :success
    assert_equal [ "Complete quarterly project milestone", "Mentor junior team member" ],
                 JSON.parse(response.body)["candidates"].map { |c| c["text"] }.sort
  end

  test "carry-forward candidates come from the most recent planned week, not the earliest" do
    older = @user.weekly_plans.create!(start_date: Date.new(2026, 8, 10))
    roles(:one).goals.create!(weekly_plan: older, description: "Older goal")

    get "/goals/carry-forward-candidates?week_start=2026-08-24", headers: auth, as: :json

    assert_response :success
    texts = JSON.parse(response.body)["candidates"].map { |c| c["text"] }
    assert_not_includes texts, "Older goal"
    assert_includes texts, "Complete quarterly project milestone"
  end

  test "carry-forward across a gap still records the link" do
    assert_difference "GoalCarryover.count", 1 do
      post "/goals/carry-forward",
        params: { week_start: "2026-09-14", goal_ids: [ goals(:one).goal_id ] }, headers: auth, as: :json
    end

    assert_response :created
    destination = Goal.find(JSON.parse(response.body)["goals"].first["goal_id"])
    assert_equal Date.new(2026, 9, 14), destination.weekly_plan.start_date
    assert_equal goals(:one), destination.carried_from.source_goal
  end

  test "carry-forward ignores ids that are not the user's" do
    assert_no_difference "GoalCarryover.count" do
      post "/goals/carry-forward",
        params: { week_start: "2026-08-24", goal_ids: [ goals(:three).goal_id ] }, headers: auth, as: :json
    end

    assert_response :created
    assert_empty JSON.parse(response.body)["goals"]
  end
end
