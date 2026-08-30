require "test_helper"

class TaskControllerTest < ActionDispatch::IntegrationTest
  test "index_fixed_appointments without a token is unauthorized" do
    get "/onboarding/fixed-appointments?week_start=#{FIXTURE_WEEK_START}", as: :json
    assert_response :unauthorized
  end

  test "index_fixed_appointments returns only the current user's fixed appointments" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    get "/onboarding/fixed-appointments?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["appointments"].size
    assert_equal "Morning workout", body["appointments"].first["title"]
  end

  test "index_fixed_appointments returns nothing for a week the user has not planned" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    get "/onboarding/fixed-appointments?week_start=2026-08-24",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_empty JSON.parse(response.body)["appointments"]
  end

  test "index_fixed_appointments with a week_start that is not a Monday is unprocessable" do
    token = JsonWebToken.encode(users(:one).to_token_payload)

    get "/onboarding/fixed-appointments?week_start=2026-08-18", # a Tuesday
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :unprocessable_entity
  end

  test "create_fixed_appointments without a token is unauthorized" do
    post "/onboarding/fixed-appointments",
      params: { week_start: FIXTURE_WEEK_START, appointments: [] }, as: :json
    assert_response :unauthorized
  end

  test "create_fixed_appointments persists appointments scoped to current_user" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/fixed-appointments",
      params: {
        week_start: FIXTURE_WEEK_START,
        appointments: [
          { title: "Gym", day_of_week: 0, start_time: "06:00", end_time: "07:00" },
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

  test "create_fixed_appointments stamps the plan for the submitted week" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/fixed-appointments",
      params: {
        week_start: FIXTURE_WEEK_START,
        appointments: [ { title: "Gym", day_of_week: 0, start_time: "06:00", end_time: "07:00" } ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal [ weekly_plans(:one).weekly_plan_id ], user.tasks.pluck(:weekly_plan_id).uniq
  end

  test "create_fixed_appointments replaces only that week's appointments" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    old = user.tasks.create!(task_name: "Old appt", is_fixed_appointment: true, day_of_week: 0,
                             start_time: "08:00", end_time: "09:00", weekly_plan: weekly_plans(:one))
    other_week = WeeklyPlan.for!(user, Date.new(2026, 8, 24))
    kept = user.tasks.create!(task_name: "Next week appt", is_fixed_appointment: true, day_of_week: 0,
                              start_time: "08:00", end_time: "09:00", weekly_plan: other_week)

    post "/onboarding/fixed-appointments",
      params: {
        week_start: FIXTURE_WEEK_START,
        appointments: [ { title: "New appt", day_of_week: 1, start_time: "10:00", end_time: "11:00" } ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_not Task.exists?(old.task_id)
    assert Task.exists?(kept.task_id)
    assert_equal [ "New appt" ], weekly_plans(:one).tasks.pluck(:task_name)
  end

  test "create_fixed_appointments does not touch another user's tasks" do
    user = users(:one)
    other_user = users(:two)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/fixed-appointments",
      params: {
        week_start: FIXTURE_WEEK_START,
        appointments: [ { title: "Mine", day_of_week: 0, start_time: "06:00", end_time: "07:00" } ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal 1, other_user.reload.tasks.count
  end

  test "index_scheduled_tasks without a token is unauthorized" do
    get "/onboarding/schedule-tasks?week_start=#{FIXTURE_WEEK_START}", as: :json
    assert_response :unauthorized
  end

  test "index_scheduled_tasks returns only the current user's non-fixed tasks" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    user.tasks.create!(task_name: "Deep work", goal_id: goals(:one).goal_id, day_of_week: 1,
                       start_time: "10:00", end_time: "11:00", weekly_plan: weekly_plans(:one))

    get "/onboarding/schedule-tasks?week_start=#{FIXTURE_WEEK_START}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["tasks"].size
    assert_equal "Deep work", body["tasks"].first["title"]
    assert_equal goals(:one).goal_id, body["tasks"].first["goal_id"]
  end

  test "create_scheduled_tasks without a token is unauthorized" do
    post "/onboarding/schedule-tasks", params: { week_start: FIXTURE_WEEK_START, tasks: [] }, as: :json
    assert_response :unauthorized
  end

  test "create_scheduled_tasks persists tasks linked to the user's own goals and activities" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/schedule-tasks",
      params: {
        week_start: FIXTURE_WEEK_START,
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
    assert_equal [ weekly_plans(:one).weekly_plan_id ],
                 user.tasks.where(is_fixed_appointment: false).pluck(:weekly_plan_id).uniq
  end

  test "create_scheduled_tasks commits a scheduled activity to the week" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    plan = WeeklyPlan.for!(user, Date.new(2026, 8, 24))
    role = user.roles.first
    goal = role.goals.create!(description: "Next week goal", weekly_plan: plan)
    activity = sharpen_the_saw_activities(:two)

    assert_empty plan.sharpen_the_saw_activities

    post "/onboarding/schedule-tasks",
      params: {
        week_start: "2026-08-24",
        tasks: [
          { title: "Reading", day_of_week: 1, start_time: "20:00", end_time: "20:30", sharpen_the_saw_activity_id: activity.sharpen_the_saw_activity_id },
          { title: "Goal work", day_of_week: 1, start_time: "09:00", end_time: "10:00", goal_id: goal.goal_id }
        ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal [ activity.sharpen_the_saw_activity_id ],
                 plan.reload.sharpen_the_saw_activities.pluck(:sharpen_the_saw_activity_id)
  end

  test "create_scheduled_tasks replaces the user's existing scheduled tasks instead of duplicating them" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    old = user.tasks.create!(task_name: "Old task", goal_id: goals(:one).goal_id, day_of_week: 0,
                             start_time: "08:00", end_time: "09:00", weekly_plan: weekly_plans(:one))

    post "/onboarding/schedule-tasks",
      params: {
        week_start: FIXTURE_WEEK_START,
        tasks: [ { title: "New task", day_of_week: 1, start_time: "10:00", end_time: "11:00", goal_id: goals(:one).goal_id } ]
      },
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
      params: {
        week_start: FIXTURE_WEEK_START,
        tasks: [ { title: "New task", day_of_week: 1, start_time: "10:00", end_time: "11:00", goal_id: goals(:one).goal_id } ]
      },
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
      params: {
        week_start: FIXTURE_WEEK_START,
        tasks: [ { title: "Mine", day_of_week: 0, start_time: "06:00", end_time: "07:00", goal_id: goals(:one).goal_id } ]
      },
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
      params: {
        week_start: FIXTURE_WEEK_START,
        tasks: [ { title: "Sneaky", day_of_week: 0, start_time: "06:00", end_time: "07:00", goal_id: other_users_goal.goal_id } ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :unprocessable_entity
    assert_equal 0, user.tasks.where(is_fixed_appointment: false).count
  end

  test "create_scheduled_tasks rejects one of the user's own goals from a different week" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/schedule-tasks",
      params: {
        week_start: "2026-08-24",
        tasks: [ { title: "Last week's goal", day_of_week: 0, start_time: "06:00", end_time: "07:00", goal_id: goals(:one).goal_id } ]
      },
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
      params: {
        week_start: FIXTURE_WEEK_START,
        tasks: [ { title: "Sneaky", day_of_week: 0, start_time: "06:00", end_time: "07:00", sharpen_the_saw_activity_id: other_users_activity.sharpen_the_saw_activity_id } ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :unprocessable_entity
    assert_equal 0, user.tasks.where(is_fixed_appointment: false).count
  end

  # ── reconcile ─────────────────────────────────────────────────────────────────────────────────
  #
  # Saving a week used to delete every task and rebuild it, which handed each one a new id and
  # reset is_completed -- so one mid-week edit erased everything the user had ticked off, and
  # /history and /analytics lost the week with it.

  def plan_and_token
    user = users(:one)
    [ user, JsonWebToken.encode(user.to_token_payload) ]
  end

  def scheduled_task_for(user, name:, completed: false, day: 3)
    user.tasks.create!(
      weekly_plan: weekly_plans(:one), goal: goals(:one), task_name: name,
      is_completed: completed, is_fixed_appointment: false,
      day_of_week: day, start_time: "09:00", end_time: "10:00"
    )
  end

  test "create_scheduled_tasks resubmitting a task_id keeps the row, its id and its completion" do
    user, token = plan_and_token
    done = scheduled_task_for(user, name: "Deep work", completed: true)

    post "/onboarding/schedule-tasks",
      params: {
        week_start: FIXTURE_WEEK_START,
        tasks: [ { task_id: done.task_id, title: "Deep work, moved", day_of_week: 4,
                   start_time: "13:00", end_time: "14:00", goal_id: goals(:one).goal_id } ]
      },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :created
    done.reload
    assert_predicate done, :is_completed, "an edit must not reset what the user already finished"
    assert_equal "Deep work, moved", done.task_name
    assert_equal 4, done.day_of_week
    assert_equal [ done.task_id ], JSON.parse(response.body)["tasks"].map { |t| t["task_id"] }
  end

  test "create_scheduled_tasks destroys an unfinished task the client no longer sends" do
    user, token = plan_and_token
    dropped = scheduled_task_for(user, name: "Never started")

    post "/onboarding/schedule-tasks",
      params: { week_start: FIXTURE_WEEK_START, tasks: [] },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :created
    assert_not Task.exists?(dropped.task_id)
  end

  # The same rule ArchiveGoal applies to a dropped goal's tasks: a completed task is a fact about
  # that week, and deleting it would let a user raise their own completion rate.
  test "create_scheduled_tasks keeps a completed task the client no longer sends" do
    user, token = plan_and_token
    done = scheduled_task_for(user, name: "Already done", completed: true)

    post "/onboarding/schedule-tasks",
      params: { week_start: FIXTURE_WEEK_START, tasks: [] },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :created
    assert Task.exists?(done.task_id)
    assert_equal [ done.task_id ], JSON.parse(response.body)["tasks"].map { |t| t["task_id"] },
                 "the response reports the week as it really stands, retained task included"
  end

  test "create_scheduled_tasks rejects a task_id that is not one of this week's tasks" do
    user, token = plan_and_token
    other_week = user.weekly_plans.create!(start_date: Date.new(2026, 8, 24))
    stranger = user.tasks.create!(
      weekly_plan: other_week, task_name: "Next week", is_fixed_appointment: false,
      day_of_week: 1, start_time: "09:00", end_time: "10:00"
    )

    post "/onboarding/schedule-tasks",
      params: {
        week_start: FIXTURE_WEEK_START,
        tasks: [ { task_id: stranger.task_id, title: "Hijack", day_of_week: 1,
                   start_time: "09:00", end_time: "10:00", goal_id: goals(:one).goal_id } ]
      },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "Unknown task id" ], JSON.parse(response.body)["errors"]
    assert_equal "Next week", stranger.reload.task_name
  end

  test "create_scheduled_tasks with no ids still behaves as onboarding expects" do
    user, token = plan_and_token
    existing = scheduled_task_for(user, name: "Old plan")

    post "/onboarding/schedule-tasks",
      params: {
        week_start: FIXTURE_WEEK_START,
        tasks: [ { title: "Fresh", day_of_week: 1, start_time: "09:00", end_time: "10:00",
                   goal_id: goals(:one).goal_id } ]
      },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :created
    assert_not Task.exists?(existing.task_id)
    assert_equal [ "Fresh" ], JSON.parse(response.body)["tasks"].map { |t| t["title"] }
  end

  test "create_fixed_appointments resubmitting a task_id keeps the row and its completion" do
    user, token = plan_and_token
    appointment = tasks(:one)
    appointment.update!(is_completed: true)

    post "/onboarding/fixed-appointments",
      params: {
        week_start: FIXTURE_WEEK_START,
        appointments: [ { task_id: appointment.task_id, title: "Morning workout", day_of_week: 1,
                          start_time: "06:00", end_time: "07:00" } ]
      },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :created
    appointment.reload
    assert_predicate appointment, :is_completed
    assert_equal 1, appointment.day_of_week
  end

  test "create_fixed_appointments rejects a task_id belonging to a scheduled task" do
    user, token = plan_and_token
    scheduled = scheduled_task_for(user, name: "Not an appointment")

    post "/onboarding/fixed-appointments",
      params: {
        week_start: FIXTURE_WEEK_START,
        appointments: [ { task_id: scheduled.task_id, title: "Sneaky", day_of_week: 1,
                          start_time: "06:00", end_time: "07:00" } ]
      },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "Unknown task id" ], JSON.parse(response.body)["errors"]
  end

  # --- PATCH /tasks/:id/completion -------------------------------------------------------------
  #
  # Until this endpoint existed, `is_completed` was read into four JSON shapes and written by none,
  # so every task in the database sat at the column default.

  test "update_completion ticks a task off" do
    task = tasks(:past_goal_missed)
    token = JsonWebToken.encode(users(:three).to_token_payload)

    patch "/tasks/#{task.task_id}/completion",
      params: { is_completed: true },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_equal({ "task_id" => task.task_id, "is_completed" => true }, JSON.parse(response.body)["task"])
    assert_predicate task.reload, :is_completed
  end

  test "update_completion unticks a task" do
    task = tasks(:past_goal_done)
    token = JsonWebToken.encode(users(:three).to_token_payload)

    patch "/tasks/#{task.task_id}/completion",
      params: { is_completed: false },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_not task.reload.is_completed
  end

  # The End-of-Day checklist lists a 6am gym session next to everything else the day held, and the
  # model forbids a fixed appointment a goal and a priority but says nothing about completion.
  test "update_completion works on a fixed appointment" do
    task = tasks(:past_fixed)
    token = JsonWebToken.encode(users(:three).to_token_payload)

    patch "/tasks/#{task.task_id}/completion",
      params: { is_completed: true },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_predicate task.reload, :is_completed
  end

  test "update_completion needs no week_start, since the row names its own week" do
    task = tasks(:past_goal_missed)
    token = JsonWebToken.encode(users(:three).to_token_payload)

    patch "/tasks/#{task.task_id}/completion",
      params: { is_completed: true },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
  end

  test "update_completion cannot reach another user's task" do
    task = tasks(:past_goal_done)
    token = JsonWebToken.encode(users(:one).to_token_payload)

    patch "/tasks/#{task.task_id}/completion",
      params: { is_completed: false },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :not_found
    assert_predicate task.reload, :is_completed
  end

  test "update_completion is unauthorized without a token" do
    patch "/tasks/#{tasks(:past_fixed).task_id}/completion", params: { is_completed: true }, as: :json
    assert_response :unauthorized
  end
end
