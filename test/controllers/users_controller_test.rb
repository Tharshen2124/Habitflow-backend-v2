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
end
