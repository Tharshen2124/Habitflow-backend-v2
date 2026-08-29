require "test_helper"

class EveningReflectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @plan = weekly_plans(:one)
  end

  def auth(user = @user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user.to_token_payload)}" }
  end

  test "without a token is unauthorized" do
    get "/weekly-plans/evening-reflections?week_start=#{FIXTURE_WEEK_START}", as: :json
    assert_response :unauthorized
  end

  test "with a week_start that is not a Monday is unprocessable" do
    get "/weekly-plans/evening-reflections?week_start=2026-08-18", headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  # ── reading a week ───────────────────────────────────────────────────────────

  test "returns the week's reflections in day order, with no summary yet" do
    get "/weekly-plans/evening-reflections?week_start=#{FIXTURE_WEEK_START}", headers: auth, as: :json
    assert_response :success

    body = JSON.parse(response.body)
    assert body["planned"]
    assert_equal [ 0, 1 ], body["reflections"].map { |r| r["day_of_week"] }
    assert_nil body["summary"]
  end

  test "returns the summary alongside the reflections once one exists" do
    @plan.create_weekly_summary!(content: "A steady week.", model: "gemini-2.5-flash",
                                 generated_at: Time.current)

    get "/weekly-plans/evening-reflections?week_start=#{FIXTURE_WEEK_START}", headers: auth, as: :json

    assert_equal "A steady week.", JSON.parse(response.body).dig("summary", "content")
  end

  test "an unplanned week reads as unplanned and is not brought into existence by looking" do
    assert_no_difference -> { WeeklyPlan.count } do
      get "/weekly-plans/evening-reflections?week_start=2026-08-24", headers: auth, as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_not body["planned"]
    assert_empty body["reflections"]
  end

  test "another user's week is invisible" do
    get "/weekly-plans/evening-reflections?week_start=#{FIXTURE_WEEK_START}",
      headers: auth(users(:two)), as: :json

    # users(:two) has their own plan for this Monday, so they see theirs -- never user one's.
    assert_empty JSON.parse(response.body)["reflections"]
  end

  # ── writing a reflection ─────────────────────────────────────────────────────

  test "writes a reflection for a day that has none" do
    assert_difference -> { EveningReflection.count }, 1 do
      put "/weekly-plans/evening-reflections",
        params: { week_start: FIXTURE_WEEK_START, day_of_week: 4, content: "Shipped the parser." },
        headers: auth, as: :json
    end

    assert_response :success
    assert_equal "Shipped the parser.", JSON.parse(response.body).dig("reflection", "content")
  end

  test "writing the same day again edits it in place rather than adding a second" do
    assert_no_difference -> { EveningReflection.count } do
      put "/weekly-plans/evening-reflections",
        params: { week_start: FIXTURE_WEEK_START, day_of_week: 0, content: "Rewritten." },
        headers: auth, as: :json
    end

    assert_response :success
    assert_equal "Rewritten.", evening_reflections(:one).reload.content
  end

  # Every day of the week is writable while the week is live -- a user reflecting on Thursday is
  # not blocked from filling in Monday, nor from writing Sunday ahead of time.
  test "any of the seven days can be written, in any order, including days still ahead" do
    # Pinned to the Wednesday of the fixture week: Saturday and Sunday have not happened yet, and
    # writing them must still be allowed. Fixtures already hold days 0 and 1.
    travel_to Date.new(2026, 8, 19) do
      [ 6, 3, 5 ].each do |day|
        put "/weekly-plans/evening-reflections",
          params: { week_start: FIXTURE_WEEK_START, day_of_week: day, content: "Day #{day}." },
          headers: auth, as: :json
        assert_response :success
      end
    end

    assert_equal [ 0, 1, 3, 5, 6 ], @plan.evening_reflections.order(:day_of_week).pluck(:day_of_week)
  end

  test "refuses a day outside the week" do
    put "/weekly-plans/evening-reflections",
      params: { week_start: FIXTURE_WEEK_START, day_of_week: 7, content: "The eighth day." },
      headers: auth, as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"].join, "Day of week"
  end

  test "refuses a reflection longer than the cap" do
    put "/weekly-plans/evening-reflections",
      params: { week_start: FIXTURE_WEEK_START, day_of_week: 4, content: "a" * 2001 },
      headers: auth, as: :json

    assert_response :unprocessable_entity
  end

  test "refuses an empty reflection" do
    put "/weekly-plans/evening-reflections",
      params: { week_start: FIXTURE_WEEK_START, day_of_week: 4, content: "  " },
      headers: auth, as: :json

    assert_response :unprocessable_entity
  end

  # The rule that keeps "a plan row exists" meaning "this week was planned": writing a reflection
  # must never be what files that row.
  test "refuses to write into a week that was never planned, and does not plan it" do
    assert_no_difference [ -> { WeeklyPlan.count }, -> { EveningReflection.count } ] do
      put "/weekly-plans/evening-reflections",
        params: { week_start: "2026-08-24", day_of_week: 0, content: "Never planned this week." },
        headers: auth, as: :json
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"].join, "Plan this week"
  end

  test "refuses to write into a week that closed long ago" do
    old = WeeklyPlan.for!(@user, 6.weeks.ago.to_date.beginning_of_week)

    put "/weekly-plans/evening-reflections",
      params: { week_start: old.start_date.iso8601, day_of_week: 0, content: "Backfilled." },
      headers: auth, as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"].join, "has ended"
  end

  # ── the week strip ───────────────────────────────────────────────────────────

  test "reports per-week counts without returning any reflection text" do
    get "/evening-reflections/weeks?from=#{FIXTURE_WEEK_START}&to=#{FIXTURE_WEEK_START}",
      headers: auth, as: :json
    assert_response :success

    weeks = JSON.parse(response.body)["weeks"]
    assert_equal 1, weeks.size
    assert_equal({ "week_start" => FIXTURE_WEEK_START, "reflection_count" => 2, "has_summary" => false },
                 weeks.first)
    assert_not_includes response.body, "Slow start"
  end

  test "the strip omits weeks the user never planned rather than inventing them" do
    get "/evening-reflections/weeks?from=2026-08-10&to=2026-08-24", headers: auth, as: :json

    assert_equal [ FIXTURE_WEEK_START ], JSON.parse(response.body)["weeks"].map { |w| w["week_start"] }
  end

  test "the strip rejects a non-Monday bound, a backwards range and an unbounded one" do
    get "/evening-reflections/weeks?from=2026-08-18&to=2026-08-24", headers: auth, as: :json
    assert_response :unprocessable_entity

    get "/evening-reflections/weeks?from=2026-08-24&to=#{FIXTURE_WEEK_START}", headers: auth, as: :json
    assert_response :unprocessable_entity

    get "/evening-reflections/weeks?from=2020-01-06&to=#{FIXTURE_WEEK_START}", headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  # --- the summary's tier -----------------------------------------------------------------------

  # The summary button has to know whether it is locked before it is pressed, and this is the
  # response the page already waits for -- so the answer arrives with the reflections rather than
  # costing a second request, and cannot flash an unlocked button it then takes back.
  test "the week reports which tier it was read for" do
    get "/weekly-plans/evening-reflections?week_start=#{FIXTURE_WEEK_START}",
        headers: auth(users(:one)), as: :json
    assert_equal false, JSON.parse(response.body)["premium"]

    premium!(users(:one))
    get "/weekly-plans/evening-reflections?week_start=#{FIXTURE_WEEK_START}",
        headers: auth(users(:one)), as: :json
    assert_equal true, JSON.parse(response.body)["premium"]
  end

  test "a week that was never planned still reports the tier" do
    get "/weekly-plans/evening-reflections?week_start=2026-09-07",
        headers: auth(users(:one)), as: :json

    assert_response :success
    assert_equal false, JSON.parse(response.body)["planned"]
    assert_equal false, JSON.parse(response.body)["premium"]
  end
end
