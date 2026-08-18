require "test_helper"

class SharpenTheSawActivityTest < ActiveSupport::TestCase
  test "active scope excludes soft-deleted activities" do
    assert_includes SharpenTheSawActivity.active, sharpen_the_saw_activities(:one)
    assert_not_includes SharpenTheSawActivity.active, sharpen_the_saw_activities(:three)
  end
end
