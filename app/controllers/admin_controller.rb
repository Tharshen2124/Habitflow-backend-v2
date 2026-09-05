# The admin dashboard: who is using this app, and what they have paid.
#
# Everything here is a **read across every account**, which is the one thing no other controller in
# this app does -- the rest are scoped to `current_user` by construction, so a bug in them leaks
# nothing. That is why the guard is a `before_action` on the whole class rather than a check inside
# each action: a new action added below is refused by default, and forgetting the guard is not
# something a diff has to catch.
#
# It is also why every payload is shaped by hand. `users` carries four bearer tokens, a refresh
# token and a password digest; `as_json` on that table would hand all six to the browser, and the
# rule "no serializer gem, shape it inline" is what makes the omission visible in this file.
#
# Not week-scoped, and it derives no weeks: every figure here is anchored on a real timestamp
# (`created_at`, `paid_at`, `updated_at`) rather than on a week boundary, so the rule that the
# server never decides what "the current week" is stays intact -- see PremiumGated#free_history_floor
# for the one place that rule is deliberately broken, and why this is not a second one.
class AdminController < ApplicationController
  include Authenticatable

  before_action :require_admin!

  # A page big enough that scrolling it is the normal gesture, small enough that it is one screen
  # of table. The cap exists so a client cannot ask for the whole users table in one request and
  # turn a paginated endpoint back into an unpaginated one.
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100

  # How far back the "recently" figures look. One window for all of them, so the cards read against
  # each other -- signups, active accounts and revenue over the same 30 days.
  RECENT_WINDOW = 30.days

  # How many months of revenue the trend returns.
  REVENUE_MONTHS = 12

  # A user counts as active if they have touched a task inside the window: `tasks.updated_at` moves
  # both when a week is replanned and when a task is ticked off, which are the two things a person
  # using this app actually does. Signing in is not a signal -- a seven-day cookie means someone can
  # be signed in for a week without opening the app once.
  def overview
    render json: {
      users: user_metrics,
      subscriptions: subscription_metrics,
      revenue: revenue_metrics
    }
  end

  # The user list, newest account first.
  def users
    scope = by_access(search(User.all, params[:q]), params[:access])
    page, per_page, total = paginate(scope)
    # A tie-break on the primary key, not decoration: `created_at` has second resolution and two
    # accounts opened in the same second would otherwise be free to swap places between requests,
    # which shows up as a row appearing on page 2 that was already on page 1.
    records = scope.order(created_at: :desc, user_id: :desc)
                   .limit(per_page).offset((page - 1) * per_page).to_a

    render json: {
      users: users_json(records),
      pagination: pagination_json(page, per_page, total)
    }
  end

  # Every invoice Stripe has told us about, newest first. Filterable by status, because the one
  # question this table gets asked outside "what came in" is "what failed".
  def payments
    scope = Payment.all
    scope = scope.where(status: params[:status]) if Payment::STATUSES.include?(params[:status])
    page, per_page, total = paginate(scope)
    # `includes(:user)` rather than a join: one extra query for the page's users beats 25.
    records = scope.includes(:user).order(created_at: :desc, payment_id: :desc)
                   .limit(per_page).offset((page - 1) * per_page)

    render json: {
      payments: records.map { |payment| payment_json(payment) },
      pagination: pagination_json(page, per_page, total)
    }
  end

  # The one **write** on this controller, and the only endpoint anywhere that changes another
  # account's row.
  #
  # Ban and unban are one action taking the state to end in rather than two, because an unban is not
  # a different fact from a ban -- it is the same column, and the control on the dashboard is a
  # toggle. The `banned` parameter is required rather than defaulted: a missing one would otherwise
  # cast to false and quietly *unban* whoever the admin meant to ban.
  def update_ban
    user = User.find_by(user_id: params[:id])
    return render json: { errors: [ "No such account" ] }, status: :not_found unless user

    banned = ActiveModel::Type::Boolean.new.cast(params[:banned])
    return render json: { errors: [ "banned must be true or false" ] }, status: :unprocessable_entity if banned.nil?

    # An admin banning themselves would be locked out of the only page that could undo it: the guard
    # is on this whole class, so their very next request would be refused before reaching here, and
    # `is_banned` is granted and revoked by no other endpoint. Nothing stops one admin banning
    # another -- both are granted by hand in the console, so the console is the way back.
    if user.user_id == current_user.user_id
      return render json: { errors: [ "You cannot ban your own account" ] }, status: :unprocessable_entity
    end

    user.update!(is_banned: banned)
    render json: { user: { user_id: user.user_id, is_banned: user.is_banned } }
  end

  private

  # 403, not 402. The paid tier's refusal means "this account has not bought this", which a user can
  # act on -- PremiumGated answers 402 precisely so the client can render an upgrade offer. This one
  # means "this account is not allowed here", which is not for sale and has no offer to make, so it
  # takes the status that already means exactly that.
  def require_admin!
    return if current_user.is_admin?

    render json: { errors: [ "This area is for administrators" ] }, status: :forbidden
  end

  # --- Overview ---------------------------------------------------------------------------------

  def user_metrics
    {
      total: User.count,
      onboarded: User.where(is_onboarded: true).count,
      new_recently: User.where(created_at: RECENT_WINDOW.ago..).count,
      # Not windowed like the two figures around it: a ban is a standing state, not something that
      # happened in the last thirty days, and the number worth seeing is how many accounts are shut
      # out right now.
      banned: User.where(is_banned: true).count,
      # DISTINCT on tasks.user_id, which the column is denormalised onto -- a task names its user
      # as well as its week, so this needs no join.
      active_recently: Task.where(updated_at: RECENT_WINDOW.ago..).distinct.count(:user_id),
      admins: User.where(is_admin: true).count
    }
  end

  def subscription_metrics
    {
      premium: User.premium.count,
      # Every status Stripe has actually put on an account, rather than a fixed list of the ones we
      # expect: `past_due` and `unpaid` are exactly the states worth seeing, and hard-coding the
      # keys here would silently drop any status Stripe adds later.
      by_status: User.where.not(subscription_status: nil).group(:subscription_status).count,
      # Accounts that have been through checkout at least once, whether or not they still pay. The
      # gap between this and `premium` is churn.
      ever_subscribed: User.where.not(stripe_customer_id: nil).count
    }
  end

  # Money, reported in **one currency at a time**.
  #
  # `payments.currency` is per row, so summing the column would add MYR to anything else Stripe ever
  # charges and call the result revenue. Instead the currency with the largest paid total is the one
  # the figures and the trend describe, and anything else is listed beside it as its own total. In
  # practice there is one Price and one currency, and this costs nothing to be right about.
  def revenue_metrics
    paid = Payment.where(status: Payment::PAID)
    totals = paid.group(:currency).sum(:amount_cents)
    primary, primary_total = totals.max_by { |_currency, cents| cents }

    return empty_revenue if primary.nil?

    in_primary = paid.where(currency: primary)
    {
      currency: primary,
      total_cents: primary_total,
      recent_cents: in_primary.where(paid_at: RECENT_WINDOW.ago..).sum(:amount_cents),
      paid_count: in_primary.count,
      failed_count: Payment.where(status: Payment::FAILED, currency: primary).count,
      monthly: monthly_revenue(in_primary),
      other_currencies: totals.except(primary)
                              .map { |currency, cents| { currency: currency, total_cents: cents } }
                              .sort_by { |row| -row[:total_cents] }
    }
  end

  def empty_revenue
    {
      currency: nil, total_cents: 0, recent_cents: 0, paid_count: 0,
      # Failures still count when nothing has succeeded -- a deployment whose every charge has
      # failed is the case this figure exists for, and it would read as "no payments" otherwise.
      failed_count: Payment.where(status: Payment::FAILED).count,
      monthly: [], other_currencies: []
    }
  end

  # Paid totals per calendar month, oldest first, with the empty months filled in so the chart has
  # a continuous axis rather than one that skips a quiet month.
  #
  # `date_trunc` runs in the connection's timezone, which Rails pins to UTC, so a payment taken late
  # on the last day of a month in a western zone lands in the next one. That is left alone
  # deliberately: this is a population-level trend, the alternative is a timezone the server does
  # not store, and being a few hours out on a month boundary changes no decision made from it.
  def monthly_revenue(scope)
    first_month = REVENUE_MONTHS.months.ago.beginning_of_month
    sums = scope.where(paid_at: first_month..)
                .group(Arel.sql("date_trunc('month', paid_at)"))
                .sum(:amount_cents)
                .transform_keys { |time| time.strftime("%Y-%m") }

    (0..REVENUE_MONTHS).map do |offset|
      month = (first_month + offset.months).strftime("%Y-%m")
      { month: month, cents: sums.fetch(month, 0) }
    end
  end

  # --- Users ------------------------------------------------------------------------------------

  # Narrows the list to banned accounts, or to the ones that can still sign in.
  #
  # Anything else -- including no parameter at all -- means every account, which is how `payments`
  # treats a status it does not recognise and for the same reason: a filter value the client made up
  # should show everything rather than nothing, since an empty table reads as a page that failed.
  ACCESS_FILTERS = { "banned" => true, "active" => false }.freeze

  def by_access(scope, access)
    ACCESS_FILTERS.key?(access) ? scope.where(is_banned: ACCESS_FILTERS[access]) : scope
  end

  # Matches an email or a username, case-insensitively, anywhere in the value.
  #
  # `sanitize_sql_like` is the whole point of this method being written out: without it a `%` typed
  # into the search box is a wildcard rather than a character, so searching for "%" returns every
  # account and searching for "a_b" quietly matches "axb".
  def search(scope, query)
    return scope if query.blank?

    term = "%#{ActiveRecord::Base.sanitize_sql_like(query.strip)}%"
    scope.where("email ILIKE :term OR username ILIKE :term", term: term)
  end

  # One page of users, with the per-user figures gathered as grouped counts over the page's ids
  # rather than a query per row -- the same shape analytics#week_analytics uses, for the same
  # reason: 25 rows would otherwise be 75 queries.
  def users_json(records)
    ids = records.map(&:user_id)
    plans = WeeklyPlan.where(user_id: ids)
    plan_counts = plans.group(:user_id).count
    latest_weeks = plans.group(:user_id).maximum(:start_date)
    spend = lifetime_spend(ids)

    records.map do |user|
      {
        user_id: user.user_id,
        username: user.username,
        email: user.email,
        created_at: user.created_at.iso8601,
        is_onboarded: user.is_onboarded,
        is_admin: user.is_admin,
        is_banned: user.is_banned,
        # The model's own answer, not a re-reading of the two columns: this is the figure the app
        # gates features on, so the dashboard must not be able to disagree with it.
        premium: user.premium?,
        subscription_status: user.subscription_status,
        subscription_period_end: user.subscription_period_end&.iso8601,
        calendar_connected: user.calendar_connected?,
        weekly_plans: plan_counts.fetch(user.user_id, 0),
        last_plan_week: latest_weeks[user.user_id]&.iso8601,
        **spend.fetch(user.user_id, { paid_cents: 0, currency: nil })
      }
    end
  end

  # What each user has actually paid, in their own currency -- grouped by (user, currency) and
  # reduced to the largest, for the same reason revenue_metrics picks one: a total that has added
  # two currencies together is not a number anyone can act on.
  def lifetime_spend(ids)
    Payment.where(user_id: ids, status: Payment::PAID)
           .group(:user_id, :currency)
           .sum(:amount_cents)
           .each_with_object({}) do |((user_id, currency), cents), acc|
      current = acc[user_id]
      acc[user_id] = { paid_cents: cents, currency: currency } if current.nil? || cents > current[:paid_cents]
    end
  end

  # --- Payments ---------------------------------------------------------------------------------

  # The user is embedded rather than referenced by id: the table is read, not navigated, and an id
  # the admin would have to look up in the list above is not an answer to "who paid this".
  def payment_json(payment)
    {
      payment_id: payment.payment_id,
      stripe_invoice_id: payment.stripe_invoice_id,
      amount_cents: payment.amount_cents,
      currency: payment.currency,
      status: payment.status,
      paid_at: payment.paid_at&.iso8601,
      created_at: payment.created_at.iso8601,
      # A payment whose user has since been deleted keeps its row -- the foreign key would refuse,
      # but the destroy cascades, so this is defensive rather than reachable today.
      user: payment.user && {
        user_id: payment.user.user_id,
        username: payment.user.username,
        email: payment.user.email
      }
    }
  end

  # --- Pagination -------------------------------------------------------------------------------

  # Plain LIMIT/OFFSET, and deliberately no gem: this is the whole feature, and the Gemfile has
  # already turned down three dependencies that would each have replaced about as much code.
  #
  # The count runs before the page is fetched so `total_pages` describes the same scope the rows
  # came from, and the page number is clamped to what exists -- asking for page 40 of 3 returns the
  # last page rather than an empty table that looks like a failure.
  def paginate(scope)
    per_page = (params[:per_page].presence&.to_i || DEFAULT_PER_PAGE).clamp(1, MAX_PER_PAGE)
    total = scope.count
    total_pages = [ (total / per_page.to_f).ceil, 1 ].max
    page = [ params[:page].to_i, 1 ].max.clamp(1, total_pages)

    [ page, per_page, total ]
  end

  def pagination_json(page, per_page, total)
    {
      page: page,
      per_page: per_page,
      total: total,
      total_pages: [ (total / per_page.to_f).ceil, 1 ].max
    }
  end
end
