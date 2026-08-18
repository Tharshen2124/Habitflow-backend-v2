require "test_helper"

class RolesControllerTest < ActionDispatch::IntegrationTest
  test "index without a token is unauthorized" do
    get "/onboarding/roles", as: :json
    assert_response :unauthorized
  end

  test "index returns the current user's roles with nested goals" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    get "/onboarding/roles", headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["roles"].size
    assert_equal "Professional", body["roles"].first["name"]
    assert_equal 2, body["roles"].first["goals"].size
  end

  test "index does not return another user's roles" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    get "/onboarding/roles", headers: { "Authorization" => "Bearer #{token}" }, as: :json

    body = JSON.parse(response.body)
    assert_not_includes body["roles"].map { |r| r["name"] }, "Parent"
  end

  test "create without a token is unauthorized" do
    post "/onboarding/roles", params: { roles: [] }, as: :json
    assert_response :unauthorized
  end

  test "create persists roles and their nested goals scoped to current_user" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/roles",
      params: {
        roles: [
          {
            name: "Athlete",
            icon_id: "dumbbell",
            goals: [
              { text: "Run a 10k", is_weekly_priority: true },
              { text: "Stretch daily" }
            ]
          }
        ]
      },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal 1, body["roles"].size
    assert_equal "Athlete", body["roles"].first["name"]
    assert_equal 2, body["roles"].first["goals"].size

    assert_equal 1, user.roles.count
    assert_equal 2, user.roles.first.goals.count
  end

  test "create replaces the user's existing roles instead of duplicating them" do
    user = users(:one)
    token = JsonWebToken.encode(user.to_token_payload)
    role = user.roles.create!(role_name: "Old Role")
    role.goals.create!(description: "Old goal")

    post "/onboarding/roles",
      params: { roles: [ { name: "New Role", icon_id: "home", goals: [ { text: "New goal" } ] } ] },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal 1, user.roles.count
    assert_equal "New Role", user.roles.first.role_name
    assert_not Role.exists?(role.role_id)
  end

  test "create does not touch another user's roles" do
    user = users(:one)
    other_user = users(:two)
    token = JsonWebToken.encode(user.to_token_payload)

    post "/onboarding/roles",
      params: { roles: [ { name: "Mine", icon_id: "home", goals: [] } ] },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :created
    assert_equal 1, other_user.reload.roles.count
  end
end
