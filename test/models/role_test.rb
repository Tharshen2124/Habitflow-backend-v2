require "test_helper"

class RoleTest < ActiveSupport::TestCase
  test "requires a role_name" do
    role = Role.new(user: users(:one))
    assert_not role.valid?
    assert_includes role.errors[:role_name], "can't be blank"
  end

  test "destroying a role destroys its goals" do
    role = roles(:one)
    assert_difference "Goal.count", -role.goals.count do
      role.destroy
    end
  end
end
