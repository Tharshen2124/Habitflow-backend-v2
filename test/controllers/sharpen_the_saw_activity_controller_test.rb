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

  test "index excludes soft-deleted activities" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    get "/onboarding/sharpen-the-saw", headers: { "Authorization" => "Bearer #{token}" }, as: :json

    body = JSON.parse(response.body)
    ids = body["activities"].map { |a| a["sharpen_the_saw_activity_id"] }
    assert_not_includes ids, sharpen_the_saw_activities(:three).sharpen_the_saw_activity_id
  end

  test "GET sharpen-the-saw-activities returns the same active activities as onboarding index" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    get "/sharpen-the-saw-activities", headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body["activities"].size
  end

  test "create_activity creates a single activity for the current user" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    assert_difference -> { user.sharpen_the_saw_activities.count }, 1 do
      post "/sharpen-the-saw-activities",
        params: { dimension: "social", activity_description: "Call a friend" },
        headers: { "Authorization" => "Bearer #{token}" }, as: :json
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "social", body["activity"]["dimension"]
    assert_equal "Call a friend", body["activity"]["activity_description"]
  end

  test "create_activity requires a dimension and description" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/sharpen-the-saw-activities",
      params: { dimension: "", activity_description: "" },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :unprocessable_entity
  end

  test "update_activity updates the activity_description" do
    activity = sharpen_the_saw_activities(:one)
    token = JsonWebToken.encode(activity.user.to_token_payload)

    patch "/sharpen-the-saw-activities/#{activity.sharpen_the_saw_activity_id}",
      params: { activity_description: "Evening jog" },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_equal "Evening jog", activity.reload.activity_description
  end

  test "update_activity 404s for another user's activity" do
    activity = sharpen_the_saw_activities(:one)
    token = JsonWebToken.encode(users(:two).to_token_payload)

    patch "/sharpen-the-saw-activities/#{activity.sharpen_the_saw_activity_id}",
      params: { activity_description: "Hijacked" },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :not_found
  end

  test "update_activity 404s for an already soft-deleted activity" do
    activity = sharpen_the_saw_activities(:three)
    token = JsonWebToken.encode(activity.user.to_token_payload)

    patch "/sharpen-the-saw-activities/#{activity.sharpen_the_saw_activity_id}",
      params: { activity_description: "Should not work" },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :not_found
  end

  test "destroy_activity soft-deletes without removing the row" do
    activity = sharpen_the_saw_activities(:one)
    token = JsonWebToken.encode(activity.user.to_token_payload)

    assert_no_difference -> { SharpenTheSawActivity.count } do
      delete "/sharpen-the-saw-activities/#{activity.sharpen_the_saw_activity_id}",
        headers: { "Authorization" => "Bearer #{token}" }, as: :json
    end

    assert_response :no_content
    assert activity.reload.is_deleted
  end

  test "destroy_activity 404s for another user's activity" do
    activity = sharpen_the_saw_activities(:one)
    token = JsonWebToken.encode(users(:two).to_token_payload)

    delete "/sharpen-the-saw-activities/#{activity.sharpen_the_saw_activity_id}",
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :not_found
    assert_not activity.reload.is_deleted
  end

  test "single-record actions require a token" do
    activity = sharpen_the_saw_activities(:one)

    post "/sharpen-the-saw-activities", params: { dimension: "social", activity_description: "x" }, as: :json
    assert_response :unauthorized

    patch "/sharpen-the-saw-activities/#{activity.sharpen_the_saw_activity_id}", params: { activity_description: "x" }, as: :json
    assert_response :unauthorized

    delete "/sharpen-the-saw-activities/#{activity.sharpen_the_saw_activity_id}", as: :json
    assert_response :unauthorized
  end
end
