require "test_helper"

class RoleTest < ActiveSupport::TestCase
  test "requires a role_name" do
    role = Role.new(user: users(:one))
    assert_not role.valid?
    assert_includes role.errors[:role_name], "can't be blank"
  end

  test "active scope excludes archived roles" do
    role = roles(:one)
    assert_includes Role.active, role

    role.update!(deleted_at: Time.current)

    assert_not_includes Role.active, role
    assert_includes Role.archived, role
    assert_predicate role, :archived?
  end

  # The whole point of archiving: a role can be retired without taking the record of what was
  # planned under it in past weeks along with it.
  test "archiving a role leaves its goals in place" do
    role = roles(:one)

    assert_no_difference "Goal.count" do
      role.update!(deleted_at: Time.current)
    end

    assert_equal 2, role.goals.reload.count
  end

  test "a role holding goals cannot be destroyed" do
    assert_raises(ActiveRecord::InvalidForeignKey) { roles(:one).destroy }
  end
end
