require "test_helper"

class TaskControllerTest < ActionDispatch::IntegrationTest
  test "index_fixed_appointments without a token is unauthorized" do
    get "/onboarding/fixed-appointments", as: :json
    assert_response :unauthorized
  end

  test "index_fixed_appointments returns only the current user's fixed appointments" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    get "/onboarding/fixed-appointments", headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["appointments"].size
    assert_equal "Morning workout", body["appointments"].first["title"]
  end

  test "create_fixed_appointments without a token is unauthorized" do
    post "/onboarding/fixed-appointments", params: { appointments: [] }, as: :json
    assert_response :unauthorized
  end

  test "create_fixed_appointments persists appointments scoped to current_user" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/fixed-appointments",
      params: {
        appointments: [
          { title: "Gym", description: "Leg day", day_of_week: 0, start_time: "06:00", end_time: "07:00" },
          { title: "Standup", day_of_week: 2, start_time: "09:00", end_time: "09:30" }
        ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal 2, body["appointments"].size
    assert_equal "Gym", body["appointments"].first["title"]

    assert_equal 2, user.tasks.count
    assert user.tasks.all?(&:is_fixed_appointment)
    assert user.tasks.all? { |t| t.goal_id.nil? && t.sharpen_the_saw_activity_id.nil? && !t.is_daily_priority }
  end

  test "create_fixed_appointments replaces the user's existing fixed appointments instead of duplicating them" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    old = user.tasks.create!(task_name: "Old appt", is_fixed_appointment: true, day_of_week: 0, start_time: "08:00", end_time: "09:00")

    post "/onboarding/fixed-appointments",
      params: { appointments: [ { title: "New appt", day_of_week: 1, start_time: "10:00", end_time: "11:00" } ] },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal 1, user.tasks.count
    assert_equal "New appt", user.tasks.first.task_name
    assert_not Task.exists?(old.task_id)
  end

  test "create_fixed_appointments does not touch another user's tasks" do
    user = users(:one)
    other_user = users(:two)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/fixed-appointments",
      params: { appointments: [ { title: "Mine", day_of_week: 0, start_time: "06:00", end_time: "07:00" } ] },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal 1, other_user.reload.tasks.count
  end

  test "index_scheduled_tasks without a token is unauthorized" do
    get "/onboarding/schedule-tasks", as: :json
    assert_response :unauthorized
  end

  test "index_scheduled_tasks returns only the current user's non-fixed tasks" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    user.tasks.create!(task_name: "Deep work", goal_id: goals(:one).goal_id, day_of_week: 1, start_time: "10:00", end_time: "11:00")

    get "/onboarding/schedule-tasks", headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["tasks"].size
    assert_equal "Deep work", body["tasks"].first["title"]
    assert_equal goals(:one).goal_id, body["tasks"].first["goal_id"]
  end

  test "create_scheduled_tasks without a token is unauthorized" do
    post "/onboarding/schedule-tasks", params: { tasks: [] }, as: :json
    assert_response :unauthorized
  end

  test "create_scheduled_tasks persists tasks linked to the user's own goals and activities" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/schedule-tasks",
      params: {
        tasks: [
          { title: "Work on milestone", day_of_week: 1, start_time: "09:00", end_time: "10:00", goal_id: goals(:one).goal_id, is_daily_priority: true },
          { title: "Morning run", day_of_week: 2, start_time: "07:00", end_time: "07:30", sharpen_the_saw_activity_id: sharpen_the_saw_activities(:one).sharpen_the_saw_activity_id }
        ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal 2, body["tasks"].size

    assert_equal 2, user.tasks.where(is_fixed_appointment: false).count
    priority_task = user.tasks.find_by(task_name: "Work on milestone")
    assert priority_task.is_daily_priority
    assert_equal goals(:one).goal_id, priority_task.goal_id
  end

  test "create_scheduled_tasks replaces the user's existing scheduled tasks instead of duplicating them" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    old = user.tasks.create!(task_name: "Old task", goal_id: goals(:one).goal_id, day_of_week: 0, start_time: "08:00", end_time: "09:00")

    post "/onboarding/schedule-tasks",
      params: { tasks: [ { title: "New task", day_of_week: 1, start_time: "10:00", end_time: "11:00", goal_id: goals(:one).goal_id } ] },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal 1, user.tasks.where(is_fixed_appointment: false).count
    assert_equal "New task", user.tasks.where(is_fixed_appointment: false).first.task_name
    assert_not Task.exists?(old.task_id)
  end

  test "create_scheduled_tasks does not touch the user's fixed appointments" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    fixed = tasks(:one)

    post "/onboarding/schedule-tasks",
      params: { tasks: [ { title: "New task", day_of_week: 1, start_time: "10:00", end_time: "11:00", goal_id: goals(:one).goal_id } ] },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert Task.exists?(fixed.task_id)
    assert user.tasks.where(is_fixed_appointment: true).exists?(task_id: fixed.task_id)
  end

  test "create_scheduled_tasks does not touch another user's tasks" do
    user = users(:one)
    other_user = users(:two)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/schedule-tasks",
      params: { tasks: [ { title: "Mine", day_of_week: 0, start_time: "06:00", end_time: "07:00", goal_id: goals(:one).goal_id } ] },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal 1, other_user.reload.tasks.count
  end

  test "create_scheduled_tasks rejects a goal_id that does not belong to the current user" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    other_users_goal = goals(:three)

    post "/onboarding/schedule-tasks",
      params: { tasks: [ { title: "Sneaky", day_of_week: 0, start_time: "06:00", end_time: "07:00", goal_id: other_users_goal.goal_id } ] },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :unprocessable_entity
    assert_equal 0, user.tasks.where(is_fixed_appointment: false).count
  end

  test "create_scheduled_tasks rejects a sharpen_the_saw_activity_id that does not belong to the current user" do
    user = users(:two)
    token = JsonWebToken.encode(user.to_token_payload)
    other_users_activity = sharpen_the_saw_activities(:one)

    post "/onboarding/schedule-tasks",
      params: { tasks: [ { title: "Sneaky", day_of_week: 0, start_time: "06:00", end_time: "07:00", sharpen_the_saw_activity_id: other_users_activity.sharpen_the_saw_activity_id } ] },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :unprocessable_entity
    assert_equal 0, user.tasks.where(is_fixed_appointment: false).count
  end
end
