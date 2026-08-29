require "test_helper"

# The auto-sync hook, tested where it is wired rather than where it runs: these are about which
# writes reach Google at all, not about what the reconcile then does.
class CalendarSyncHooksTest < ActionDispatch::IntegrationTest
  ZONE = "Asia/Kuala_Lumpur".freeze

  def auth(user) = { "Authorization" => "Bearer #{JsonWebToken.encode(user.to_token_payload)}", "X-Time-Zone" => ZONE }

  def post_tasks(user, headers: nil)
    post "/weekly-plans/tasks",
         params: { week_start: FIXTURE_WEEK_START,
                   tasks: [ { title: "Fresh task", day_of_week: 1, start_time: "10:00", end_time: "11:00" } ] },
         headers: headers || auth(user), as: :json
  end

  test "saving a week's tasks syncs that week" do
    assert_enqueued_with(job: CalendarSyncJob, args: [ users(:calendar).user_id, FIXTURE_WEEK_START, ZONE ]) do
      post_tasks(users(:calendar))
    end
    assert_response :created
  end

  test "saving fixed appointments syncs that week" do
    assert_enqueued_with(job: CalendarSyncJob) do
      post "/weekly-plans/fixed-appointments",
           params: { week_start: FIXTURE_WEEK_START,
                     appointments: [ { title: "Dentist", day_of_week: 4, start_time: "09:00", end_time: "09:30" } ] },
           headers: auth(users(:calendar)), as: :json
    end
    assert_response :created
  end

  test "a user who has never connected costs nothing" do
    assert_no_enqueued_jobs(only: CalendarSyncJob) { post_tasks(users(:one)) }
    assert_response :created
  end

  test "the Allow Sync switch turns the automatic path off" do
    users(:calendar).update!(calendar_sync_enabled: false)

    assert_no_enqueued_jobs(only: CalendarSyncJob) { post_tasks(users(:calendar)) }
    assert_response :created
  end

  # Automatic sync is the paid half of the calendar feature. Connecting, pushing by hand and
  # choosing what exports are all free -- only the part that fires on every write is not.
  test "a free account never reaches the automatic path" do
    users(:calendar).update!(subscription_status: nil, subscription_period_end: nil)

    assert_no_enqueued_jobs(only: CalendarSyncJob) { post_tasks(users(:calendar)) }
    assert_response :created
  end

  test "an account whose paid period has run out never reaches it either" do
    users(:calendar).update!(subscription_period_end: 1.day.ago)

    assert_no_enqueued_jobs(only: CalendarSyncJob) { post_tasks(users(:calendar)) }
    assert_response :created
  end

  # The switch is left as the user set it. It is a preference, not a grant -- the same reason
  # User#disconnect_calendar! leaves it alone -- so upgrading restores automatic sync without
  # asking anyone to go and find a switch they never touched.
  test "being free does not clear the switch the user set" do
    users(:calendar).update!(subscription_status: nil, subscription_period_end: nil)

    post_tasks(users(:calendar))

    assert_equal true, users(:calendar).reload.calendar_sync_enabled
  end

  # A guessed zone silently files a whole week at the wrong hour, which is worse than not filing it.
  test "a request with no usable time zone skips the sync rather than guessing" do
    assert_no_enqueued_jobs(only: CalendarSyncJob) do
      post_tasks(users(:calendar), headers: auth(users(:calendar)).except("X-Time-Zone"))
    end
    assert_response :created

    assert_no_enqueued_jobs(only: CalendarSyncJob) do
      post_tasks(users(:calendar), headers: auth(users(:calendar)).merge("X-Time-Zone" => "Nowhere/Bogus"))
    end
  end

  test "renaming a role syncs, because its name is in every event under it" do
    assert_enqueued_with(job: CalendarSyncJob) do
      patch "/roles/#{roles(:calendar).role_id}",
            params: { week_start: FIXTURE_WEEK_START, name: "Doctoral researcher" },
            headers: auth(users(:calendar)), as: :json
    end
    assert_response :success
  end

  test "archiving a role syncs, because it takes this week's unfinished tasks off the calendar" do
    assert_enqueued_with(job: CalendarSyncJob) do
      delete "/roles/#{roles(:calendar).role_id}?week_start=#{FIXTURE_WEEK_START}",
             headers: auth(users(:calendar)), as: :json
    end
    assert_response :success
  end

  test "editing a goal syncs, because its text and its priority flag are on the event" do
    assert_enqueued_with(job: CalendarSyncJob) do
      patch "/goals/#{goals(:calendar_plain).goal_id}",
            params: { week_start: FIXTURE_WEEK_START, description: "Read five papers" },
            headers: auth(users(:calendar)), as: :json
    end
    assert_response :success
  end

  test "renaming a Sharpen the Saw activity syncs" do
    assert_enqueued_with(job: CalendarSyncJob) do
      patch "/sharpen-the-saw-activities/#{sharpen_the_saw_activities(:calendar).sharpen_the_saw_activity_id}",
            params: { week_start: FIXTURE_WEEK_START, activity_description: "Call home on Saturdays" },
            headers: auth(users(:calendar)), as: :json
    end
    assert_response :success
  end

  # Nothing in the event body depends on is_completed, so re-pushing thirty events to change
  # nothing is pure cost.
  test "ticking a task off does not sync" do
    assert_no_enqueued_jobs(only: CalendarSyncJob) do
      patch "/tasks/#{tasks(:calendar_plain).task_id}/completion",
            params: { is_completed: true }, headers: auth(users(:calendar)), as: :json
    end
    assert_response :success
  end

  # A new goal has no tasks yet, so there is nothing on the calendar for it to change.
  test "creating a goal does not sync" do
    assert_no_enqueued_jobs(only: CalendarSyncJob) do
      post "/goals", params: { week_start: FIXTURE_WEEK_START, role_id: roles(:calendar).role_id, description: "New goal" },
           headers: auth(users(:calendar)), as: :json
    end
    assert_response :created
  end

  test "the job re-checks the switch rather than trusting it from enqueue time" do
    users(:calendar).update!(calendar_sync_enabled: false)

    calls = 0
    stubbing(SyncWeekToCalendar, :call, ->(*) { calls += 1 }) do
      CalendarSyncJob.perform_now(users(:calendar).user_id, FIXTURE_WEEK_START, ZONE)
    end

    assert_equal 0, calls
  end

  test "the job resolves its week and runs the reconcile" do
    seen = nil
    stubbing(SyncWeekToCalendar, :call, ->(**kwargs) {
      seen = kwargs
      SyncWeekToCalendar::Result.new(written: 0, deleted: 0, error: nil)
    }) do
      CalendarSyncJob.perform_now(users(:calendar).user_id, FIXTURE_WEEK_START, ZONE)
    end

    assert_equal Date.new(2026, 8, 17), seen[:week_start]
    assert_equal ZONE, seen[:time_zone]
  end
end
