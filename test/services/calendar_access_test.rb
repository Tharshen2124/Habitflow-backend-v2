require "test_helper"

class CalendarAccessTest < ActiveSupport::TestCase
  setup { @user = users(:calendar) }

  test "an unexpired token is reused without a round trip" do
    token = stubbing(GoogleOauthClient, :refresh_access_token, ->(*) { flunk "must not refresh" }) do
      CalendarAccess.token_for(@user)
    end

    assert_equal "fixture-calendar-access-token", token
  end

  # Refreshed a little early rather than exactly on the boundary: a token with four seconds left
  # expires mid-sync, and re-running thirty writes is worse than one extra refresh.
  test "a token inside the expiry margin is refreshed and persisted" do
    @user.update!(calendar_token_expires_at: 30.seconds.from_now)

    token = stubbing(GoogleOauthClient, :refresh_access_token,
                     { "access_token" => "fresh-at", "expires_in" => 3600 }) do
      CalendarAccess.token_for(@user)
    end

    assert_equal "fresh-at", token
    assert_equal "fresh-at", @user.reload.calendar_access_token
    assert_operator @user.calendar_token_expires_at, :>, 50.minutes.from_now
  end

  # invalid_grant means the user revoked access from their own Google settings. Nothing here can
  # fix that, and staying "connected" would show a card whose every action fails.
  test "a revoked grant disconnects the user rather than failing forever" do
    @user.update!(calendar_token_expires_at: 1.minute.ago)

    token = stubbing(GoogleOauthClient, :refresh_access_token, { "error" => "invalid_grant" }) do
      CalendarAccess.token_for(@user)
    end

    assert_nil token
    assert_not @user.reload.calendar_connected?
    assert_nil @user.calendar_refresh_token
  end

  test "a transient refresh failure leaves the connection intact" do
    @user.update!(calendar_token_expires_at: 1.minute.ago)

    token = stubbing(GoogleOauthClient, :refresh_access_token, nil) { CalendarAccess.token_for(@user) }

    assert_nil token
    assert @user.reload.calendar_connected?
  end

  test "a user with no refresh token never reaches Google" do
    @user.update!(calendar_refresh_token: nil)

    assert_nil stubbing(GoogleOauthClient, :refresh_access_token, ->(*) { flunk "must not refresh" }) {
      CalendarAccess.token_for(@user)
    }
  end

  test "ensure_calendar reuses the one already stored" do
    id = stubbing(GoogleCalendarClient, :create_calendar, ->(*) { flunk "must not create" }) do
      CalendarAccess.ensure_calendar(@user, "token", "Asia/Kuala_Lumpur")
    end

    assert_equal "c_habitflow@group.calendar.google.com", id
  end

  # The recovery path for a user who deleted the HabitFlow calendar in Google's own UI: every
  # stored event id now points into a calendar that no longer exists, and a stale id is worse than
  # none -- the next sync would patch an event on a dead calendar and read the 404 as "the user
  # deleted this one event".
  test "recreating the calendar clears every stored event id" do
    @user.tasks.update_all(google_calendar_event_id: "stale", sync_status: "synced")

    id = stubbing(GoogleCalendarClient, :create_calendar,
                  GoogleCalendarClient::Result.new(body: { "id" => "cal-rebuilt" }, error: nil)) do
      CalendarAccess.ensure_calendar(@user, "token", "Asia/Kuala_Lumpur", recreate: true)
    end

    assert_equal "cal-rebuilt", id
    assert_equal "cal-rebuilt", @user.reload.calendar_id
    assert_empty @user.tasks.where.not(google_calendar_event_id: nil)
  end

  test "a failed creation stores nothing" do
    @user.update!(calendar_id: nil)

    id = stubbing(GoogleCalendarClient, :create_calendar,
                  GoogleCalendarClient::Result.new(body: nil, error: :unavailable)) do
      CalendarAccess.ensure_calendar(@user, "token", "Asia/Kuala_Lumpur")
    end

    assert_nil id
    assert_nil @user.reload.calendar_id
  end
end
