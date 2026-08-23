require "test_helper"

class UserTest < ActiveSupport::TestCase
  def valid_attributes
    { email: "new-user@example.com", username: "new_user", password: "password123" }
  end

  test "valid with email, username, and password" do
    assert User.new(valid_attributes).valid?
  end

  test "invalid without email" do
    user = User.new(valid_attributes.merge(email: nil))
    assert_not user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  test "invalid with malformed email" do
    user = User.new(valid_attributes.merge(email: "not-an-email"))
    assert_not user.valid?
    assert_includes user.errors[:email], "is invalid"
  end

  test "email uniqueness is case-insensitive" do
    User.create!(valid_attributes)
    dup = User.new(valid_attributes.merge(email: valid_attributes[:email].upcase, username: "someone_else"))
    assert_not dup.valid?
    assert_includes dup.errors[:email], "has already been taken"
  end

  test "email is normalized to a stripped, downcased form" do
    user = User.create!(valid_attributes.merge(email: "  Mixed-Case@Example.com "))
    assert_equal "mixed-case@example.com", user.email
  end

  test "invalid without username" do
    user = User.new(valid_attributes.merge(username: nil))
    assert_not user.valid?
    assert_includes user.errors[:username], "can't be blank"
  end

  test "invalid with duplicate username" do
    User.create!(valid_attributes)
    dup = User.new(valid_attributes.merge(email: "other@example.com", username: valid_attributes[:username]))
    assert_not dup.valid?
    assert_includes dup.errors[:username], "has already been taken"
  end

  test "password is required when there is no google_uid" do
    user = User.new(valid_attributes.merge(password: nil))
    assert_not user.valid?
    assert_includes user.errors[:password_digest], "can't be blank"
    assert_includes user.errors.full_messages, "Password can't be blank"
  end

  test "an unrelated update to an existing user does not fail password validation" do
    user = users(:one)
    assert user.update(is_onboarded: true)
  end

  test "password is not required when google_uid is present" do
    user = User.new(email: "google-user@example.com", username: "google_user", google_uid: "google-uid-123", password: nil)
    assert user.valid?
  end

  test "authenticate returns the user for the correct password" do
    user = User.create!(valid_attributes)
    assert_equal user, user.authenticate("password123")
  end

  test "authenticate returns false for the wrong password" do
    user = User.create!(valid_attributes)
    assert_not user.authenticate("wrong-password")
  end

  test "to_token_payload exposes only non-sensitive claims" do
    user = User.create!(valid_attributes)
    payload = user.to_token_payload
    assert_equal user.user_id, payload[:user_id]
    assert_equal user.email, payload[:email]
    assert_equal user.username, payload[:username]
    assert_equal user.is_onboarded, payload[:is_onboarded]
    assert_not payload.key?(:password_digest)
  end

  test "link_google_account returns nil and creates nothing when nothing matches" do
    assert_no_difference "User.count" do
      assert_nil User.link_google_account(google_uid: "new-google-uid", email: "brand-new@example.com")
    end
  end

  test "link_google_account returns the existing user when google_uid matches" do
    existing = users(:two)
    assert_no_difference "User.count" do
      user = User.link_google_account(google_uid: existing.google_uid, email: "different@example.com")
      assert_equal existing, user
    end
  end

  test "link_google_account links to an existing user by email when google_uid does not match" do
    existing = users(:one)
    assert_nil existing.google_uid
    assert_no_difference "User.count" do
      user = User.link_google_account(google_uid: "linked-google-uid", email: existing.email.upcase)
      assert_equal existing.user_id, user.user_id
      assert_equal "linked-google-uid", user.reload.google_uid
    end
  end

  test "link_google_account leaves the linked account's password sign-in working" do
    existing = users(:one)
    User.link_google_account(google_uid: "linked-google-uid", email: existing.email)
    assert existing.reload.authenticate("password123")
  end
end
