require "test_helper"

class AuthenticationControllerTest < ActionDispatch::IntegrationTest
  # Minitest 6 dropped Minitest::Mock/Object#stub from core, so this hand-rolls
  # a temporary class-method override for the duration of the block.
  def stub_google_oauth(exchange_result:, profile_result:)
    original_exchange = GoogleOauthClient.method(:exchange_code_for_tokens)
    original_fetch = GoogleOauthClient.method(:fetch_profile)
    GoogleOauthClient.define_singleton_method(:exchange_code_for_tokens) { |_code| exchange_result }
    GoogleOauthClient.define_singleton_method(:fetch_profile) { |_access_token| profile_result }
    yield
  ensure
    GoogleOauthClient.define_singleton_method(:exchange_code_for_tokens, original_exchange)
    GoogleOauthClient.define_singleton_method(:fetch_profile, original_fetch)
  end

  test "signup creates a user and does not return a token" do
    assert_difference "User.count", 1 do
      post "/signup", params: { email: "fresh@example.com", username: "fresh_user", password: "password123" }
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "fresh@example.com", body["user"]["email"]
    assert_not body.key?("token")
  end

  test "signup with a duplicate email is rejected" do
    existing = users(:one)
    assert_no_difference "User.count" do
      post "/signup", params: { email: existing.email, username: "someone_new", password: "password123" }
    end
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"].join, "Email"
  end

  test "signup with missing fields is rejected" do
    assert_no_difference "User.count" do
      post "/signup", params: { email: "", username: "", password: "" }
    end
    assert_response :unprocessable_entity
  end

  test "POST login with correct credentials returns a token" do
    user = users(:one)
    post "/login", params: { email: user.email, password: "password123" }
    assert_response :success
    assert JSON.parse(response.body)["token"].present?
  end

  test "POST login with the wrong password is unauthorized" do
    user = users(:one)
    post "/login", params: { email: user.email, password: "wrong-password" }
    assert_response :unauthorized
  end

  test "POST login rejects a Google-only account (no password set)" do
    google_only = User.create!(email: "google-only@example.com", username: "google_only", google_uid: "gid-1", password: nil)
    post "/login", params: { email: google_only.email, password: "anything" }
    assert_response :unauthorized
  end

  test "GET login redirects to Google's consent screen with a signed state param" do
    get "/login"
    assert_response :redirect
    location = URI(response.location)
    assert_equal "accounts.google.com", location.host
    query = URI.decode_www_form(location.query).to_h
    assert query["state"].present?
    assert_equal "google_oauth_state", JsonWebToken.decode(query["state"])[:purpose]
  end

  test "callback redirects with an error when Google reports access_denied" do
    get "/callback", params: { error: "access_denied" }
    assert_response :redirect
    assert_equal "http://localhost:3001/login#error=access_denied", response.location
  end

  test "callback redirects with an error when the state param is missing or invalid" do
    get "/callback", params: { code: "some-code" }
    assert_response :redirect
    assert_equal "http://localhost:3001/login#error=invalid_state", response.location
  end

  test "callback redirects with an error when the state param was signed for a different purpose" do
    bad_state = JsonWebToken.encode({ purpose: "something_else" }, exp: 5.minutes.from_now)
    get "/callback", params: { code: "some-code", state: bad_state }
    assert_response :redirect
    assert_equal "http://localhost:3001/login#error=invalid_state", response.location
  end

  test "callback signs in a user Google is already linked to" do
    existing = users(:two)
    state = JsonWebToken.encode({ purpose: "google_oauth_state" }, exp: 5.minutes.from_now)
    tokens = { "access_token" => "at", "refresh_token" => "rt", "expires_in" => 3600, "scope" => "openid email profile" }
    profile = { "sub" => existing.google_uid, "email" => existing.email, "name" => existing.username }

    stub_google_oauth(exchange_result: tokens, profile_result: profile) do
      assert_no_difference "User.count" do
        get "/callback", params: { code: "some-code", state: state }
      end
    end

    assert_response :redirect
    assert_match %r{\Ahttp://localhost:3001/login#token=}, response.location
    assert_equal "at", existing.reload.google_access_token
  end

  test "callback refuses to open an account for an unknown Google address" do
    state = JsonWebToken.encode({ purpose: "google_oauth_state" }, exp: 5.minutes.from_now)
    tokens = { "access_token" => "at", "refresh_token" => "rt", "expires_in" => 3600, "scope" => "openid email profile" }
    profile = { "sub" => "brand-new-google-uid", "email" => "new-google-user@example.com", "name" => "New Googler" }

    stub_google_oauth(exchange_result: tokens, profile_result: profile) do
      assert_no_difference "User.count" do
        get "/callback", params: { code: "some-code", state: state }
      end
    end

    assert_response :redirect
    assert_equal "http://localhost:3001/login#error=no_account", response.location
  end

  test "callback links Google to an account that signed up with an email and password" do
    existing = users(:one)
    state = JsonWebToken.encode({ purpose: "google_oauth_state" }, exp: 5.minutes.from_now)
    tokens = { "access_token" => "at", "refresh_token" => "rt", "expires_in" => 3600, "scope" => "openid email profile" }
    profile = { "sub" => "linked-google-uid", "email" => existing.email, "name" => existing.username }

    stub_google_oauth(exchange_result: tokens, profile_result: profile) do
      assert_no_difference "User.count" do
        get "/callback", params: { code: "some-code", state: state }
      end
    end

    assert_response :redirect
    assert_match %r{\Ahttp://localhost:3001/login#token=}, response.location
    assert_equal "linked-google-uid", existing.reload.google_uid
  end
end
