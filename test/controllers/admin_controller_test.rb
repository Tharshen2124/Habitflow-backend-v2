require "test_helper"

class AdminControllerTest < ActionDispatch::IntegrationTest
  def auth(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user.to_token_payload)}" }
  end

  def admin = users(:admin)

  def get_json(path, user: admin)
    get path, headers: auth(user), as: :json
    JSON.parse(response.body)
  end

  # Search terms go through CGI.escape rather than being interpolated raw: "%" is a valid thing to
  # type into a search box and an invalid percent-escape in a URL, so the test that matters most
  # here would otherwise never reach the controller at all.
  def search_json(query, **options)
    get_json("/admin/users?q=#{CGI.escape(query)}", **options)
  end

  # --- who may look ------------------------------------------------------------------------------

  # Asserted over all three actions rather than one, because the guard is what stands between an
  # ordinary account and every other account's email address. A guard that held on two of three
  # would be the whole bug.
  ADMIN_PATHS = [ "/admin/overview", "/admin/users", "/admin/payments" ].freeze

  test "every admin path is unauthorized without a token" do
    ADMIN_PATHS.each do |path|
      get path, as: :json
      assert_response :unauthorized, "#{path} let an anonymous request through"
    end
  end

  test "every admin path is forbidden to an ordinary account" do
    ADMIN_PATHS.each do |path|
      get path, headers: auth(users(:one)), as: :json
      assert_response :forbidden, "#{path} let a non-admin through"
    end
  end

  # 403, not the 402 the paid tier answers. The client branches on the status to decide between an
  # upgrade offer and a plain refusal, so the two must not be confusable.
  test "a refusal is 403 and not payment required" do
    get "/admin/users", headers: auth(users(:one)), as: :json
    assert_response :forbidden
    assert_equal [ "This area is for administrators" ], JSON.parse(response.body)["errors"]
  end

  # The claim in the token is a hint for the sidebar; the column is the authority. A token minted
  # while the flag was set must not outlive it.
  test "a token minted before the flag was revoked no longer opens the door" do
    stale = auth(admin)
    admin.update!(is_admin: false)

    get "/admin/users", headers: stale, as: :json
    assert_response :forbidden
  end

  test "every admin path is open to an admin" do
    ADMIN_PATHS.each do |path|
      get path, headers: auth(admin), as: :json
      assert_response :success, "#{path} refused an admin"
    end
  end

  # --- overview ----------------------------------------------------------------------------------

  test "user metrics count the whole table, admins included" do
    metrics = get_json("/admin/overview")["users"]

    assert_equal User.count, metrics["total"]
    assert_equal User.where(is_onboarded: true).count, metrics["onboarded"]
    assert_equal 1, metrics["admins"]
  end

  test "new accounts are counted inside the recent window and not outside it" do
    before = get_json("/admin/overview")["users"]["new_recently"]

    User.create!(username: "brand_new", email: "brand-new@example.com", password: "password123")
    aged = User.create!(username: "long_ago", email: "long-ago@example.com", password: "password123")
    aged.update_column(:created_at, 90.days.ago)

    assert_equal before + 1, get_json("/admin/overview")["users"]["new_recently"]
  end

  # Activity is "touched a task recently", not "signed in": the token lives seven days, so being
  # signed in says nothing about having opened the app.
  test "active accounts are the ones with a task touched inside the window" do
    Task.update_all(updated_at: 90.days.ago)
    assert_equal 0, get_json("/admin/overview")["users"]["active_recently"]

    tasks(:one).update!(updated_at: Time.current)
    metrics = get_json("/admin/overview")["users"]

    assert_equal 1, metrics["active_recently"]
  end

  test "the premium count agrees with User#premium? row by row" do
    premium!(users(:one))

    assert_equal User.all.count(&:premium?), get_json("/admin/overview")["subscriptions"]["premium"]
  end

  # The scope is SQL and the predicate is Ruby, so they can drift. This is the case that catches it:
  # a subscription Stripe still calls "active" whose period has run out is not premium.
  test "a lapsed period is not premium in the count either" do
    users(:one).update!(subscription_status: "active", subscription_period_end: 1.day.ago)
    subscriptions = get_json("/admin/overview")["subscriptions"]

    assert_equal User.all.count(&:premium?), subscriptions["premium"]
    assert_not users(:one).premium?, "the fixture under test is still premium"
    # Still reported under its raw Stripe status, which is the point of showing the breakdown
    # beside the count: "active but lapsed" is a state worth being able to see.
    assert_equal User.where(subscription_status: "active").count, subscriptions["by_status"]["active"]
  end

  test "ever_subscribed counts accounts with a Stripe customer whether or not they still pay" do
    before = get_json("/admin/overview")["subscriptions"]
    users(:subscriber).update!(subscription_status: "canceled", subscription_period_end: 1.day.ago)
    after = get_json("/admin/overview")["subscriptions"]

    # The account stopped paying and stayed counted. The gap between the two figures is churn,
    # which is the only reason to report both.
    assert_equal before["premium"] - 1, after["premium"]
    assert_equal before["ever_subscribed"], after["ever_subscribed"]
    assert_equal 1, after["ever_subscribed"]
  end

  # --- revenue -----------------------------------------------------------------------------------

  test "revenue sums paid invoices and leaves failed ones out of the total" do
    revenue = get_json("/admin/overview")["revenue"]

    assert_equal "myr", revenue["currency"]
    assert_equal 5000, revenue["total_cents"]
    assert_equal 2, revenue["paid_count"]
    assert_equal 1, revenue["failed_count"]
  end

  test "the recent figure counts only what was paid inside the window" do
    # The fixtures pay 2500 forty days ago and 2500 five days ago.
    assert_equal 2500, get_json("/admin/overview")["revenue"]["recent_cents"]
  end

  test "a second currency is reported beside the primary rather than added to it" do
    Payment.create!(user: users(:subscriber), stripe_invoice_id: "in_usd", amount_cents: 900,
                    currency: "usd", status: Payment::PAID, paid_at: 2.days.ago)
    revenue = get_json("/admin/overview")["revenue"]

    assert_equal "myr", revenue["currency"]
    assert_equal 5000, revenue["total_cents"], "a foreign currency was added into the primary total"
    assert_equal [ { "currency" => "usd", "total_cents" => 900 } ], revenue["other_currencies"]
  end

  test "with no payments at all the revenue block is zeroed rather than absent" do
    Payment.delete_all
    revenue = get_json("/admin/overview")["revenue"]

    assert_nil revenue["currency"]
    assert_equal 0, revenue["total_cents"]
    assert_equal [], revenue["monthly"]
  end

  # A deployment whose every charge failed reads as "no revenue" -- but not as "no payments".
  test "failures are still counted when nothing has succeeded" do
    Payment.where(status: Payment::PAID).delete_all
    revenue = get_json("/admin/overview")["revenue"]

    assert_nil revenue["currency"]
    assert_equal 1, revenue["failed_count"]
  end

  test "the monthly trend is continuous and lands each payment in its own month" do
    monthly = get_json("/admin/overview")["revenue"]["monthly"]

    assert_equal AdminController::REVENUE_MONTHS + 1, monthly.length
    assert_equal monthly.map { |m| m["month"] }.sort, monthly.map { |m| m["month"] },
                 "months came back out of order"
    assert_equal 5000, monthly.sum { |m| m["cents"] }
    assert_operator monthly.count { |m| m["cents"].positive? }, :>=, 1
  end

  # --- the user list -----------------------------------------------------------------------------

  test "the user list never carries a credential" do
    body = get_json("/admin/users?per_page=100")
    forbidden = %w[password_digest google_access_token google_refresh_token
                   calendar_access_token calendar_refresh_token stripe_customer_id]

    body["users"].each do |user|
      assert_empty user.keys & forbidden, "#{user['email']} leaked #{(user.keys & forbidden).join(', ')}"
    end
  end

  test "users come back newest first" do
    users = get_json("/admin/users?per_page=100")["users"]
    timestamps = users.map { |u| u["created_at"] }

    assert_equal timestamps.sort.reverse, timestamps
  end

  test "a user row carries its plan count, its latest planned week and what it has paid" do
    row = search_json("fixture-subscriber")["users"].first

    assert_equal users(:subscriber).username, row["username"]
    assert_equal 5000, row["paid_cents"], "the failed invoice was counted as paid"
    assert_equal "myr", row["currency"]
    assert row["premium"]
  end

  test "a user who has paid nothing reports zero rather than nothing" do
    row = search_json("fixture-one")["users"].first

    assert_equal 0, row["paid_cents"]
    assert_nil row["currency"]
    assert_equal users(:one).weekly_plans.count, row["weekly_plans"]
  end

  test "the latest planned week is the newest week that user planned" do
    row = search_json("fixture-three")["users"].first

    assert_equal users(:three).weekly_plans.maximum(:start_date).iso8601, row["last_plan_week"]
  end

  # --- search ------------------------------------------------------------------------------------

  test "search matches an email or a username, case-insensitively" do
    by_email = search_json("FIXTURE-SUBSCRIBER@EXAMPLE.COM")["users"]
    by_username = search_json("Fixture_Subscriber")["users"]

    assert_equal [ users(:subscriber).user_id ], by_email.map { |u| u["user_id"] }
    assert_equal [ users(:subscriber).user_id ], by_username.map { |u| u["user_id"] }
  end

  test "search matches on a fragment" do
    assert_operator search_json("fixture")["pagination"]["total"], :>=, 6
  end

  # Without escaping, "%" is a wildcard rather than a character: it would match every account, so
  # the emptiest possible search would return the whole table.
  test "a percent typed into the search box matches nothing rather than everything" do
    assert_equal 0, search_json("%")["pagination"]["total"]
  end

  # And "_" would match any single character, so searching for one username would quietly return
  # its near-neighbours -- the failure nobody notices, because the account looked for is in there.
  test "an underscore matches an underscore and not any character" do
    User.create!(username: "fixtureXone", email: "fixture-x-one@example.com", password: "password123")

    matched = search_json("fixture_one")["users"].map { |u| u["username"] }

    assert_equal [ "fixture_one" ], matched
  end

  test "a search that matches nothing is an empty page, not an error" do
    body = search_json("nobody-by-that-name")

    assert_response :success
    assert_equal [], body["users"]
    assert_equal 0, body["pagination"]["total"]
    assert_equal 1, body["pagination"]["total_pages"]
  end

  # --- pagination --------------------------------------------------------------------------------

  test "a page carries only its own rows and the totals describe the whole scope" do
    body = get_json("/admin/users?per_page=2&page=1")

    assert_equal 2, body["users"].length
    assert_equal User.count, body["pagination"]["total"]
    assert_equal (User.count / 2.0).ceil, body["pagination"]["total_pages"]
  end

  test "walking every page visits every user exactly once" do
    seen = []
    total_pages = get_json("/admin/users?per_page=2")["pagination"]["total_pages"]

    (1..total_pages).each do |page|
      seen.concat(get_json("/admin/users?per_page=2&page=#{page}")["users"].map { |u| u["user_id"] })
    end

    assert_equal User.pluck(:user_id).sort, seen.sort
    assert_equal seen.length, seen.uniq.length, "a user appeared on two pages"
  end

  test "a page beyond the end is clamped to the last one rather than answering empty" do
    body = get_json("/admin/users?per_page=2&page=999")

    assert_equal body["pagination"]["total_pages"], body["pagination"]["page"]
    assert_not_empty body["users"]
  end

  test "page zero and a negative page are the first page" do
    first = get_json("/admin/users?per_page=2&page=1")["users"]

    assert_equal first, get_json("/admin/users?per_page=2&page=0")["users"]
    assert_equal first, get_json("/admin/users?per_page=2&page=-5")["users"]
  end

  # The cap is what stops a client turning a paginated endpoint back into an unpaginated one.
  test "per_page is clamped to the maximum" do
    assert_equal AdminController::MAX_PER_PAGE,
                 get_json("/admin/users?per_page=100000")["pagination"]["per_page"]
    assert_equal AdminController::DEFAULT_PER_PAGE,
                 get_json("/admin/users")["pagination"]["per_page"]
  end

  # --- payments ----------------------------------------------------------------------------------

  test "payments come back newest first, each naming who paid" do
    body = get_json("/admin/payments")

    assert_equal Payment.count, body["pagination"]["total"]
    row = body["payments"].first
    assert_equal users(:subscriber).email, row.dig("user", "email")
    assert_equal "myr", row["currency"]
  end

  test "payments can be filtered to failures" do
    body = get_json("/admin/payments?status=failed")

    assert_equal 1, body["pagination"]["total"]
    assert_equal [ "failed" ], body["payments"].map { |p| p["status"] }
    assert_nil body["payments"].first["paid_at"]
  end

  test "an unrecognised status filter is ignored rather than answering empty" do
    assert_equal Payment.count, get_json("/admin/payments?status=nonsense")["pagination"]["total"]
  end

  test "reading the dashboard writes nothing" do
    assert_no_difference [ -> { User.count }, -> { Payment.count }, -> { WeeklyPlan.count } ] do
      ADMIN_PATHS.each { |path| get path, headers: auth(admin), as: :json }
    end
  end
end
