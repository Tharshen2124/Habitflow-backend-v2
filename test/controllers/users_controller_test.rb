require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  test "complete_onboarding without a token is unauthorized" do
    patch "/users/complete_onboarding"
    assert_response :unauthorized
  end

  test "complete_onboarding with an invalid token is unauthorized" do
    patch "/users/complete_onboarding", headers: { "Authorization" => "Bearer not-a-real-token" }
    assert_response :unauthorized
  end

  test "complete_onboarding with a valid token flips is_onboarded to true" do
    user = users(:one)
    assert_not user.is_onboarded
    token = JsonWebToken.encode(user.to_token_payload)

    patch "/users/complete_onboarding", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :success
    assert JSON.parse(response.body)["user"]["is_onboarded"]
    assert user.reload.is_onboarded
  end

  # ── the End-of-Day check-in time ─────────────────────────────────────────────

  def auth(user = users(:one))
    { "Authorization" => "Bearer #{JsonWebToken.encode(user.to_token_payload)}" }
  end

  test "eod_time without a token is unauthorized" do
    get "/users/eod-time", as: :json
    assert_response :unauthorized
  end

  test "eod_time defaults to nine in the evening" do
    get "/users/eod-time", headers: auth, as: :json

    assert_response :success
    assert_equal "21:00", JSON.parse(response.body)["eod_time"]
  end

  # It goes over the wire as "HH:MM" in both directions: the column is a bare `time`, but a
  # serialized timestamp is not what a time input reads or writes.
  test "update_eod_time stores the new time and echoes it back as HH:MM" do
    patch "/users/eod-time", params: { eod_time: "07:30" }, headers: auth, as: :json

    assert_response :success
    assert_equal "07:30", JSON.parse(response.body)["eod_time"]
    assert_equal "07:30", users(:one).reload.eod_time.strftime("%H:%M")
  end

  # A `time` column casts what it cannot parse to nil, so without the model validation this would
  # surface as a not-null violation rather than a 422.
  test "update_eod_time refuses a value that is not a time of day" do
    patch "/users/eod-time", params: { eod_time: "half past nine" }, headers: auth, as: :json

    assert_response :unprocessable_entity
    assert_equal "21:00", users(:one).reload.eod_time.strftime("%H:%M")
  end

  test "update_eod_time changes only the caller's own time" do
    patch "/users/eod-time", params: { eod_time: "06:15" }, headers: auth(users(:two)), as: :json

    assert_equal "06:15", users(:two).reload.eod_time.strftime("%H:%M")
    assert_equal "21:00", users(:one).reload.eod_time.strftime("%H:%M")
  end
end
