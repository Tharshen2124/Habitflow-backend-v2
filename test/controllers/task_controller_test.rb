require "test_helper"

class TaskControllerTest < ActionDispatch::IntegrationTest
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
end
