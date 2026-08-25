require "test_helper"

class CalendarExportPreferenceTest < ActiveSupport::TestCase
  def preference(raw) = CalendarExportPreference.new(raw)

  test "an unset preference exports everything" do
    prefs = preference(nil)

    assert prefs.exports?(tasks(:calendar_priority))
    assert prefs.exports?(tasks(:calendar_activity))
    assert prefs.exports?(tasks(:calendar_fixed))
  end

  # The whole reason the column stores exclusions. An inclusion list would leave a role created
  # after the preference was last saved silently off the calendar, with nothing on screen to say so.
  test "a role created after the preference was saved still exports" do
    prefs = preference("excluded_role_ids" => [ roles(:one).role_id ])
    fresh = users(:calendar).roles.create!(role_name: "Runner", icon_id: "activity", color_id: "teal")
    goal = fresh.goals.create!(weekly_plan_id: weekly_plans(:calendar).weekly_plan_id, description: "10k")
    task = tasks(:calendar_plain).tap { |t| t.update!(goal: goal) }

    assert prefs.exports?(task)
  end

  test "an excluded role's tasks are held back, and only that role's" do
    prefs = preference("excluded_role_ids" => [ roles(:calendar).role_id ])

    assert_not prefs.exports?(tasks(:calendar_priority))
    assert prefs.exports?(tasks(:calendar_activity))
  end

  test "an excluded dimension holds back its activity's tasks" do
    assert_not preference("excluded_dimensions" => [ "social" ]).exports?(tasks(:calendar_activity))
    assert preference("excluded_dimensions" => [ "physical" ]).exports?(tasks(:calendar_activity))
  end

  test "fixed appointments are their own switch" do
    assert_not preference("fixed_appointments" => false).exports?(tasks(:calendar_fixed))
    assert preference("fixed_appointments" => false).exports?(tasks(:calendar_priority))
  end

  # /settings offers three categories and an unlinked task belongs to none of them, so there is
  # nothing the user could have unticked to exclude it.
  test "a task linked to nothing still exports" do
    unlinked = tasks(:calendar_plain).tap { |t| t.update!(goal: nil) }

    assert preference("excluded_role_ids" => [ roles(:calendar).role_id ]).exports?(unlinked)
  end

  test "sanitise keeps the three keys and coerces their types" do
    sanitised = CalendarExportPreference.sanitise(
      "fixed_appointments" => "false",
      "excluded_role_ids" => [ "12", 31 ],
      "excluded_dimensions" => [ :social ],
      "something_else" => "dropped"
    )

    assert_equal [ "fixed_appointments", "excluded_dimensions", "excluded_role_ids" ], sanitised.keys
    assert_equal [ 12, 31 ], sanitised["excluded_role_ids"]
    assert_equal [ "social" ], sanitised["excluded_dimensions"]
    # The string, not the boolean -- a form-encoded client sends "false" and `"false" != false`.
    assert_equal false, sanitised["fixed_appointments"]
  end

  test "the string \"false\" switches fixed appointments off, like the boolean" do
    assert_not preference("fixed_appointments" => "false").exports?(tasks(:calendar_fixed))
    assert preference("fixed_appointments" => "true").exports?(tasks(:calendar_fixed))
  end

  test "a stored blob missing keys added since reads as the default for them" do
    prefs = preference("excluded_role_ids" => [])

    assert prefs.exports?(tasks(:calendar_fixed))
    assert_equal [], prefs.to_h["excluded_dimensions"]
  end
end
