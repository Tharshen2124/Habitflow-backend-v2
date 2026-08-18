require "test_helper"

class SharpenTheSawActivityControllerTest < ActionDispatch::IntegrationTest
  test "index without a token is unauthorized" do
    get "/onboarding/sharpen-the-saw", as: :json
    assert_response :unauthorized
  end

  test "index returns the current user's activities" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    get "/onboarding/sharpen-the-saw", headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body["activities"].size
    assert_equal %w[physical mental], body["activities"].map { |a| a["dimension"] }
  end

  test "index does not return another user's activities" do
    user = users(:two)
    token = JsonWebToken.encode(user.to_token_payload)

    get "/onboarding/sharpen-the-saw", headers: { "Authorization" => "Bearer #{token}" }, as: :json

    body = JSON.parse(response.body)
    assert_equal [], body["activities"]
  end
end
