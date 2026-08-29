require "test_helper"

class WeeklySummariesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @plan = weekly_plans(:one)
    # The summary is a paid feature. Everything below is about what happens *behind* that gate --
    # the preconditions, the upstream failures, the write-once rule -- so both accounts are put on
    # the paid tier here and the gate itself is asserted on its own, at the end of the file.
    premium!(@user, users(:two))
  end

  def auth(user = @user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user.to_token_payload)}" }
  end

  def summarised(text = "You protected your mornings, and Wednesday shows what that bought you.")
    GeminiSummaryClient::Result.new(content: text, error: nil)
  end

  def write_whole_week(plan = @plan)
    (0..6).each do |day|
      plan.evening_reflections.find_or_create_by!(day_of_week: day) { |r| r.content = "Day #{day}." }
    end
  end

  # Standing in for Gemini with something that fails the test if it is reached. Every precondition
  # has to be settled before the expensive call, not after it.
  def refusing_to_call
    ->(*) { flunk "Gemini was called before the preconditions were checked" }
  end

  def generate(week_start: FIXTURE_WEEK_START, headers: nil)
    post "/weekly-plans/weekly-summary",
      params: { week_start: week_start }, headers: headers || auth, as: :json
  end

  test "without a token is unauthorized" do
    post "/weekly-plans/weekly-summary", params: { week_start: FIXTURE_WEEK_START }, as: :json
    assert_response :unauthorized
  end

  test "with a week_start that is not a Monday is unprocessable" do
    generate(week_start: "2026-08-18")
    assert_response :unprocessable_entity
  end

  # ── the preconditions, all of them before the call ───────────────────────────

  test "refuses a week with fewer than seven reflections, without calling Gemini" do
    stubbing(GeminiSummaryClient, :summarise, refusing_to_call) do
      assert_no_difference -> { WeeklySummary.count } do
        generate
      end
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"].join, "all 7 reflections"
  end

  test "refuses a week that was never planned, and does not plan it" do
    stubbing(GeminiSummaryClient, :summarise, refusing_to_call) do
      assert_no_difference -> { WeeklyPlan.count } do
        generate(week_start: "2026-08-24")
      end
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"].join, "Plan this week"
  end

  test "refuses a second summary, without calling Gemini again" do
    write_whole_week
    @plan.create_weekly_summary!(content: "The first and only one.", model: "gemini-2.5-flash",
                                 generated_at: Time.current)

    stubbing(GeminiSummaryClient, :summarise, refusing_to_call) do
      assert_no_difference -> { WeeklySummary.count } do
        generate
      end
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"].join, "already been summarised"
  end

  # ── generating ───────────────────────────────────────────────────────────────

  test "summarises a fully written week, once, recording the model that wrote it" do
    write_whole_week

    stubbing(GeminiSummaryClient, :summarise, summarised) do
      assert_difference -> { WeeklySummary.count }, 1 do
        generate
      end
    end

    assert_response :created
    body = JSON.parse(response.body)["summary"]
    assert_equal "You protected your mornings, and Wednesday shows what that bought you.", body["content"]
    assert_equal GeminiSummaryClient::MODEL, body["model"]
    assert body["generated_at"].present?
  end

  test "hands Gemini all seven reflections" do
    write_whole_week
    received = nil

    stubbing(GeminiSummaryClient, :summarise, ->(reflections) { received = reflections; summarised }) do
      generate
    end

    assert_equal (0..6).to_a, received.map(&:day_of_week)
  end

  # A summary is written once and never regenerated, so a failed call has to leave nothing behind:
  # storing a half-answer would make it the user's summary forever.
  test "stores nothing when the service is unavailable" do
    write_whole_week
    failure = GeminiSummaryClient::Result.new(content: nil, error: :unavailable)

    stubbing(GeminiSummaryClient, :summarise, failure) do
      assert_no_difference -> { WeeklySummary.count } do
        generate
      end
    end

    assert_response :bad_gateway
  end

  # The free tier allows five requests a minute. Being throttled is something to wait out, and it
  # must not read to the user as the feature being broken.
  test "reports being throttled as its own answer, and stores nothing" do
    write_whole_week
    throttled = GeminiSummaryClient::Result.new(content: nil, error: :rate_limited)

    stubbing(GeminiSummaryClient, :summarise, throttled) do
      assert_no_difference -> { WeeklySummary.count } do
        generate
      end
    end

    assert_response :too_many_requests
    assert_includes JSON.parse(response.body)["errors"].join, "try again in a minute"
  end

  # Read-only applies to reflections, not to this. A week that closed with all seven written is
  # exactly the week most worth summarising.
  test "summarises a week that has already ended" do
    old = WeeklyPlan.for!(@user, 6.weeks.ago.to_date.beginning_of_week)
    write_whole_week(old)

    stubbing(GeminiSummaryClient, :summarise, summarised) do
      generate(week_start: old.start_date.iso8601)
    end

    assert_response :created
  end

  test "another user cannot summarise this week" do
    write_whole_week

    stubbing(GeminiSummaryClient, :summarise, refusing_to_call) do
      generate(headers: auth(users(:two)))
    end

    assert_response :unprocessable_entity
  end

  # --- the premium gate ------------------------------------------------------------------------

  test "a free account is refused, and Gemini is never called" do
    @user.update!(subscription_status: nil, subscription_period_end: nil)
    write_whole_week

    assert_no_difference "WeeklySummary.count" do
      stubbing(GeminiSummaryClient, :summarise, refusing_to_call) { generate }
    end

    assert_response :payment_required
  end

  # The gate is declared before find_weekly_plan, so it answers before the week is even looked up.
  # Which means a free account cannot use the shape of the refusal to learn anything about the week.
  test "a free account is refused before the week is resolved" do
    @user.update!(subscription_status: nil, subscription_period_end: nil)

    generate(week_start: "2026-09-07")

    assert_response :payment_required
  end

  # Cancelling leaves the status "active" until the period runs out, so the period is half the
  # question -- and a lapsed account must lose the feature, not keep it until a webhook says so.
  test "an account whose paid period has run out is refused" do
    @user.update!(subscription_status: "active", subscription_period_end: 1.day.ago)
    write_whole_week

    stubbing(GeminiSummaryClient, :summarise, refusing_to_call) { generate }

    assert_response :payment_required
  end
end
