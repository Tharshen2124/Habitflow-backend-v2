require "test_helper"

class CalendarControllerTest < ActionDispatch::IntegrationTest
  ZONE = "Asia/Kuala_Lumpur".freeze

  def auth(user) = { "Authorization" => "Bearer #{JsonWebToken.encode(user.to_token_payload)}", "X-Time-Zone" => ZONE }

  def body = JSON.parse(response.body)

  test "every endpoint refuses an unauthenticated caller" do
    get "/calendar", as: :json
    assert_response :unauthorized
    get "/calendar/connect", as: :json
    assert_response :unauthorized
    post "/calendar/sync", params: { week_start: FIXTURE_WEEK_START }, as: :json
    assert_response :unauthorized
    delete "/calendar", as: :json
    assert_response :unauthorized
  end

  test "show reports a user who has never connected" do
    get "/calendar", headers: auth(users(:one)), as: :json

    assert_response :success
    assert_equal false, body["calendar"]["connected"]
    assert_equal true, body["calendar"]["export_preference"]["fixed_appointments"]
  end

  test "show reports a connected user" do
    get "/calendar", headers: auth(users(:calendar)), as: :json

    assert_response :success
    assert_equal true, body["calendar"]["connected"]
  end

  test "connect returns a consent URL whose state names the user and expires soon" do
    get "/calendar/connect", headers: auth(users(:one)), as: :json

    assert_response :success
    url = body["url"]
    assert_includes url, "accounts.google.com"
    assert_includes url, CGI.escape(GoogleOauthClient::CALENDAR_SCOPE)

    state = JsonWebToken.decode(URI.decode_www_form(URI(url).query).to_h["state"])
    assert_equal CalendarController::STATE_PURPOSE, state[:purpose]
    assert_equal users(:one).user_id, state[:user_id]
    assert_equal ZONE, state[:time_zone]
    assert_operator state[:exp], :<=, 5.minutes.from_now.to_i
  end

  test "connect refuses a request with no usable time zone" do
    get "/calendar/connect",
        headers: auth(users(:one)).merge("X-Time-Zone" => "Nowhere/Bogus"), as: :json

    assert_response :unprocessable_entity
  end

  # A state minted for sign-in must not be replayable here. The purpose claim is only worth having
  # if the two flows disagree about it.
  test "the callback refuses a sign-in state" do
    state = JsonWebToken.encode({ purpose: AuthenticationController::STATE_PURPOSE, user_id: users(:one).user_id })

    get "/calendar/callback", params: { code: "x", state: state }

    assert_redirected_to %r{/settings#calendar_error=invalid_state}
    assert_nil users(:one).reload.calendar_refresh_token
  end

  test "the callback stores the grant and creates the calendar" do
    user = users(:one)
    state = JsonWebToken.encode({ purpose: CalendarController::STATE_PURPOSE, user_id: user.user_id, time_zone: ZONE })

    stubbing(GoogleOauthClient, :exchange_calendar_code, {
      "access_token" => "at", "refresh_token" => "rt", "expires_in" => 3600,
      "scope" => GoogleOauthClient::CALENDAR_SCOPE
    }) do
      stubbing(GoogleCalendarClient, :create_calendar,
               GoogleCalendarClient::Result.new(body: { "id" => "cal-new" }, error: nil)) do
        get "/calendar/callback", params: { code: "x", state: state }
      end
    end

    assert_redirected_to %r{/settings#calendar=connected}
    user.reload
    assert_equal "rt", user.calendar_refresh_token
    assert_equal "cal-new", user.calendar_id
    assert user.calendar_connected?
  end

  # Google lets a user untick a scope and still send a code. Storing the grant anyway would show a
  # connected card whose every action fails.
  test "the callback refuses a grant that does not carry the calendar scope" do
    user = users(:one)
    state = JsonWebToken.encode({ purpose: CalendarController::STATE_PURPOSE, user_id: user.user_id, time_zone: ZONE })

    stubbing(GoogleOauthClient, :exchange_calendar_code, {
      "access_token" => "at", "refresh_token" => "rt", "expires_in" => 3600, "scope" => "openid email"
    }) do
      get "/calendar/callback", params: { code: "x", state: state }
    end

    assert_redirected_to %r{/settings#calendar_error=calendar_scope_declined}
    assert_nil user.reload.calendar_refresh_token
  end

  test "settings round-trip through jsonb and enqueue a reconcile" do
    assert_enqueued_with(job: CalendarSyncJob) do
      patch "/calendar/settings",
            params: { week_start: FIXTURE_WEEK_START, sync_enabled: true,
                      export_preference: { fixed_appointments: false, excluded_role_ids: [ roles(:calendar).role_id ] } },
            headers: auth(users(:calendar)), as: :json
    end

    assert_response :success
    stored = users(:calendar).reload.export_preference
    assert_equal false, stored["fixed_appointments"]
    assert_equal [ roles(:calendar).role_id ], stored["excluded_role_ids"]
    assert_equal false, body["calendar"]["export_preference"]["fixed_appointments"]
  end

  test "turning the switch off stops the automatic reconcile" do
    patch "/calendar/settings",
          params: { week_start: FIXTURE_WEEK_START, sync_enabled: false, export_preference: {} },
          headers: auth(users(:calendar)), as: :json

    assert_response :success
    assert_equal false, users(:calendar).reload.calendar_sync_enabled
  end

  test "sync refuses a user with no connection, without calling Google" do
    stubbing(GoogleCalendarClient, :list_events, ->(*) { flunk "Google must not be called" }) do
      post "/calendar/sync", params: { week_start: FIXTURE_WEEK_START }, headers: auth(users(:one)), as: :json
    end

    assert_response :unprocessable_entity
  end

  test "sync refuses a week_start that is not a Monday" do
    post "/calendar/sync", params: { week_start: "2026-08-18" }, headers: auth(users(:calendar)), as: :json

    assert_response :unprocessable_entity
    assert_match(/Monday/, body["errors"].first)
  end

  test "sync refuses an unusable time zone" do
    post "/calendar/sync", params: { week_start: FIXTURE_WEEK_START },
         headers: auth(users(:calendar)).merge("X-Time-Zone" => "Nowhere/Bogus"), as: :json

    assert_response :unprocessable_entity
  end

  test "sync reports what it wrote and stamps the time" do
    stubbing(SyncWeekToCalendar, :call, SyncWeekToCalendar::Result.new(written: 4, deleted: 1, error: nil)) do
      post "/calendar/sync", params: { week_start: FIXTURE_WEEK_START }, headers: auth(users(:calendar)), as: :json
    end

    assert_response :success
    assert_equal 4, body["written"]
    assert_equal 1, body["deleted"]
    assert users(:calendar).reload.calendar_synced_at.present?
  end

  test "a throttle is reported as one, and an outage as an outage" do
    stubbing(SyncWeekToCalendar, :call, SyncWeekToCalendar::Result.new(written: 0, deleted: 0, error: :rate_limited)) do
      post "/calendar/sync", params: { week_start: FIXTURE_WEEK_START }, headers: auth(users(:calendar)), as: :json
    end
    assert_response :too_many_requests

    stubbing(SyncWeekToCalendar, :call, SyncWeekToCalendar::Result.new(written: 0, deleted: 0, error: :unavailable)) do
      post "/calendar/sync", params: { week_start: FIXTURE_WEEK_START }, headers: auth(users(:calendar)), as: :json
    end
    assert_response :bad_gateway
  end

  test "disconnecting deletes the calendar, revokes the grant and clears the row" do
    deleted = []
    revoked = []

    stubbing(GoogleCalendarClient, :delete_calendar, ->(_t, id) { deleted << id; GoogleCalendarClient::Result.new(body: {}, error: nil) }) do
      stubbing(GoogleOauthClient, :revoke, ->(t) { revoked << t; true }) do
        delete "/calendar", headers: auth(users(:calendar)), as: :json
      end
    end

    assert_response :success
    assert_equal [ "c_habitflow@group.calendar.google.com" ], deleted
    assert_equal [ "fixture-calendar-access-token" ], revoked

    user = users(:calendar).reload
    assert_not user.calendar_connected?
    assert_nil user.calendar_id
    assert_nil user.calendar_refresh_token
    assert_equal false, body["calendar"]["connected"]
  end

  # The switch is a preference, not part of the grant: reconnecting should not make the user
  # re-tick something they never touched.
  # --- the paid half ---------------------------------------------------------------------------

  # Only automatic sync is paid for. Pressing Sync now is the free tier's whole way of getting a
  # schedule onto Google, so it must keep working -- it runs inline here and never goes through
  # CalendarSyncable, which is exactly what that split is built on.
  test "a free account can still sync by hand" do
    users(:calendar).update!(subscription_status: nil, subscription_period_end: nil)

    stubbing(SyncWeekToCalendar, :call, SyncWeekToCalendar::Result.new(written: 4, deleted: 1, error: nil)) do
      post "/calendar/sync", params: { week_start: FIXTURE_WEEK_START }, headers: auth(users(:calendar)), as: :json
    end

    assert_response :success
    assert_equal 4, body["written"]
  end

  test "a free account can still connect, choose categories and disconnect" do
    users(:calendar).update!(subscription_status: nil, subscription_period_end: nil)

    patch "/calendar/settings",
          params: { week_start: FIXTURE_WEEK_START, sync_enabled: true,
                    export_preference: { fixed_appointments: false } },
          headers: auth(users(:calendar)), as: :json

    assert_response :success
    assert_equal false, body["calendar"]["export_preference"]["fixed_appointments"]
  end

  # The switch reports what the user set even while nothing acts on it. The client reads `premium`
  # beside it and renders the switch off and locked; storing a lie here would mean an upgrade
  # silently failed to bring automatic sync back.
  test "the settings say which tier they were read for, and keep the stored switch either way" do
    get "/calendar", headers: auth(users(:calendar)), as: :json
    assert_equal true, body["premium"]

    users(:calendar).update!(subscription_status: nil, subscription_period_end: nil)
    get "/calendar", headers: auth(users(:calendar)), as: :json

    assert_equal false, body["premium"]
    assert_equal true, body["calendar"]["sync_enabled"]
  end

  test "disconnecting leaves the sync preference alone" do
    users(:calendar).update!(calendar_sync_enabled: false)

    stubbing(GoogleCalendarClient, :delete_calendar, GoogleCalendarClient::Result.new(body: {}, error: nil)) do
      stubbing(GoogleOauthClient, :revoke, true) { delete "/calendar", headers: auth(users(:calendar)), as: :json }
    end

    assert_equal false, users(:calendar).reload.calendar_sync_enabled
  end
end
