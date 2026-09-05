# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Stack

Rails 8.1.3.1 (API-only, `config.api_only = true`), Ruby 3.4.7, PostgreSQL. Uses Rails 8's Solid trio (`solid_cache`, `solid_queue`, `solid_cable`) instead of Redis. Deploys via Kamal (`.kamal/`), not docker-compose.

## Commands

- `bin/ci` — runs the full local pipeline in order: setup, rubocop, bundler-audit, brakeman, `bin/rails test`, then `db:seed:replant` in test env. Run this before committing; it mirrors CI exactly.
- `bin/rails test` — run tests (Minitest, **not RSpec** — there is no `spec/` dir, no factory_bot).
- `bin/rubocop` — lint (style is `rubocop-rails-omakase`, no custom overrides).
- `bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error` — static security analysis.
- `bin/bundler-audit` — gem vulnerability audit.

## Architecture

- API-only Rails app — controllers inherit from `ActionController::API`, no view templates.
- No GraphQL; plain REST-style JSON controllers. JSON is shaped by private `*_json` methods inline in each controller — there is no serializer gem.
- Models: `User`, `Role`, `Goal`, `GoalCarryover`, `Task`, `WeeklyPlan`, `SharpenTheSawActivity`, `WeeklyPlanStsActivity`. Auth is JWT (`app/lib/json_web_token.rb`) via the `Authenticatable` concern; Google OAuth via `app/services/google_oauth_client.rb`.
- **Google signs a user in; it never signs one up.** `User.link_google_account` finds by `google_uid`,
  falls back to linking by email, and returns nil rather than creating -- an account only ever comes
  from `POST /signup`, which requires an email, a username and a password. The callback turns that
  nil into `#error=no_account`. `password_digest`'s presence check stays conditional on
  `google_uid.blank?` only for rows that predate the rule; every new account has a password.
- CORS is enabled (`rack-cors` gem + `config/initializers/cors.rb`); the frontend at `next-app` calls this API for real, including in its Playwright suite.
- Secrets are **environment variables read with `ENV.fetch`**, loaded from `.env.local` by
  `dotenv-rails` in development and test and from the real environment in production (dotenv is
  not in the production group). `Rails.application.credentials` is referenced nowhere in `app/`,
  `config/` or `lib/`, and `credentials.yml.enc` holds only the generator's default
  `secret_key_base`. `.env.test` exists because dotenv deliberately does not load `.env.local`
  in test, which is why CI passes with no secrets at all.

### Conventions the code follows but the generators do not

- Every model overrides `self.primary_key`; every association spells out `foreign_key:` **and** `primary_key:`. Migrations use `id: false` + `t.primary_key :<name>_id`, and declare timestamps manually with `default: -> { "CURRENT_TIMESTAMP" }` rather than `t.timestamps`.
- Association **declaration order is destroy order** — see the comment in `user.rb`, which is load-bearing.
- Controllers rescue `ActiveRecord::RecordInvalid` and render `{ errors: [...] }` with 422.
- Comments explain *why*, not *what*.

### Week scoping and soft delete

Every goal- and task-writing endpoint is scoped to a weekly plan the **client** names via a
`week_start` param (always a Monday) — the server never derives "the current week", because it
stores no timezone for the user. See the `WeekScoped` concern and `Week-Scoped-Controllers.md`.

Roles, goals and Sharpen the Saw activities are soft-deleted with a `deleted_at` timestamp and a
`scope :active`; nothing that a past week references is ever destroyed. `ArchiveRole` and
`ArchiveGoal` (`app/services/`) are the single implementation of that rule, shared by the standing
pages and the onboarding re-submit. `ERD_businnes_rules.md` has the full retention policy.

Four consequences worth knowing before touching a week-scoped endpoint:

- **A read must use `find_weekly_plan`, not `set_weekly_plan`.** Only a write creates a week. A plan
  row existing is the client's only answer to "is this week planned?", and the `/weekly-plan` flow
  picks which week to offer from that answer, so a read that files a row corrupts it.
- **`/history` is the exception to `.active`.** Planning surfaces filter archived roles, dropped
  goals and deleted activities out; `HistoryController` deliberately does not, because a past week
  has to read as it was recorded. It is the reason those rows are soft-deleted rather than
  destroyed, so do not "fix" its missing scopes. It is also the only reader of `goal_carryovers`
  outside planning: `#lineage_depths` loads the user's whole chain in one query and walks it in
  memory, because a goal on its fifth week is otherwise four more round trips per goal on the page.
- **`TaskController#update_completion` is the only writer of `tasks.is_completed`,** and the only
  action in that controller that is not week-scoped — a task row already names its week. The bulk
  creates deliberately do not permit the column: they reconcile a whole week's plan, and marking one
  task done is not a replanning of the week.
- **`TaskController` reconciles by `task_id` rather than rebuilding.** Rebuilding reset
  `is_completed` on every row, and `/history` and `/analytics` resolve a week through
  `task -> goal -> role`. A submitted id is updated in place; an id-less task is created; a task the
  client stops sending is destroyed only if unfinished, which is `ArchiveGoal`'s rule.

### Stripe

`SubscriptionsController` is the paid tier, and the only controller with a second unauthenticated
action: `skip_before_action :authenticate_request!, only: [ :webhook ]`, where a signature over
`request.raw_post` stands in for the bearer token. **The raw body, never `params`** — the signature is
over the exact bytes Stripe sent, and a re-serialised hash is not those bytes.

`stripe` is the one HTTP client gem here, against the rule `GeminiSummaryClient` and
`GoogleCalendarClient` both state in comments. The Gemfile says why: those are outbound calls where a
bug means a failed sync, whereas verifying an inbound signature is a security boundary where one
silently hands out free subscriptions. Everything goes through `StripeClient`, which is the only file
that names the gem and the seam the tests replace with `stubbing` — **do not add webmock or vcr**,
which this suite has now declined three times.

Three rules hold the design together:

- **The Customer is created before checkout starts**, not on `checkout.session.completed`. That is
  what makes the arrival order of that event and `invoice.paid` stop mattering — `stripe_customer_id`
  is already set, so an invoice landing first still resolves to a user.
- **Everything is safe to run twice.** Stripe delivers at least once and replays anything that does
  not answer 2xx, so an event type with no handler must still return 200. `ApplyStripeSubscription`
  copies every field off the event rather than deriving it, and `payments.stripe_invoice_id` is unique.
- **`subscription_period_end` comes from the subscription's *item*.** `current_period_end` was moved
  off `Subscription` and onto `SubscriptionItem` in the 2025 API versions, and the gem is pinned well
  past that. A deleted subscription can arrive carrying no items at all.

**`payments` is filled by the webhook and by nothing else** — which is why a development machine
that never ran `stripe listen` shows premium accounts and zero revenue. `subscriptions#confirm`
writes the subscription half of the truth from the browser redirect and deliberately does not write
a payment: a payment is a fact Stripe reports, not something to infer from a redirect. So the money
half simply never arrives if the webhook road is not connected.

`BackfillStripePayments` (`rails stripe:backfill_payments`) is the catch-up. It lists each
customer's invoices through `StripeClient.list_invoices` — the one call here that *asks* about
invoices rather than being told — and hands each to the same `RecordStripePayment` the webhook
calls, so a row it writes is indistinguishable from one the webhook would have. Re-running is a
no-op. It records only `paid` and `uncollectible`: `draft` and `open` have not resolved and `void`
was cancelled, the same line the webhook draws by listening for `invoice.paid` and
`invoice.payment_failed` alone.

`User#premium?` checks the period as well as the status, and the second half is not redundant:
cancelling sets `cancel_at_period_end` and leaves the status `"active"` until the period ends, so one
missed webhook would otherwise leave a lapsed account premium forever. It is deliberately **not** a
JWT claim — that token lives seven days in a cookie and a plan can lapse in minutes.

### The paid tier

`PremiumGated` is the whole of it: `require_premium!` for a feature withheld outright, and
`FREE_HISTORY_WEEKS` / `free_history_floor` for the one withheld in part. Four things read it.

| Feature | Where | Free tier gets |
| --- | --- | --- |
| AI weekly summary | `WeeklySummariesController#create` | 402, before the week is resolved and long before Gemini is called |
| Analytics | `AnalyticsController#show` | 402 |
| History | `HistoryController#show` / `#weeks` | The 3 most recent finished weeks; `#weeks` clamps its range, `#show` answers 402 |
| Auto-sync to Google | `CalendarSyncable#sync_calendar_later` | Nothing — but **Sync now** still works |

Three things about it are load-bearing:

- **402, not 403.** The two 403s in this app mean the other thing: `subscriptions#confirm` refuses
  a checkout session belonging to somebody else, and `AdminController` refuses an account that is
  not an administrator. A status nothing but the paid tier answers is what lets `next-app` render a
  refusal as an upgrade offer rather than a red sentence — which is why `lib/api.ts` throws an
  `ApiError` carrying the status instead of a bare `Error`. "You have not paid for this" has an
  offer to make; "you are not allowed here" does not, and `AdminDenied` deliberately makes none.
- **Auto-sync is gated at the one enqueue site**, not on the nine actions that reach it, and
  `CalendarSyncJob` re-checks at run time because a job can outlive the subscription that enqueued
  it. `calendar_sync_enabled` is left as the user set it — it is a preference, not a grant, so
  upgrading restores automatic sync without anyone re-ticking a switch. Pushing **by hand** stays
  free: `calendar#sync` runs inline and never comes through `CalendarSyncable`.
- **`free_history_floor` is the one place the server derives "the current week"**, which it
  otherwise refuses to do. A paywall cannot take its boundary from the client: `from`/`to` arrive in
  the request, and an account naming its own cut-off could walk backwards three weeks at a time
  through all of its history. It uses the `Date.current - 1` backstop
  `EveningReflectionsController#week_has_closed?` already uses, with the slack running in the
  user's favour.

`premium?` is not a JWT claim and there is no `GET /me`, so the client learns its tier from the
response each gated page **already waits for** — a top-level `premium` key on
`evening_reflections#index`, on every `calendar` response, and on `history#weeks`. That costs no
extra request and, more to the point, cannot draw a control unlocked and then take it back.
`/analytics` is the exception: its only request is the one being refused, so it reads the 402 itself.

`users(:calendar)` is premium in the fixtures, because every auto-sync assertion would otherwise be
asserting a job that is now correctly never enqueued. `test_helper.rb`'s `premium!` puts an account
on the paid tier for the suites that are about what happens *behind* a gate; `db/seeds.rb` seeds one
local account for the Playwright test that needs a real paid session against a real backend.

### The admin dashboard

`AdminController` is the one controller whose reads are **not scoped to `current_user`**. Every
other controller here is scoped by construction, so a bug in one leaks nothing; this one answers
"every account" and "every invoice", which is why the guard is a `before_action` on the whole class
rather than a check inside each action — an action added later is refused by default.

An admin is `users.is_admin`, a column rather than an `admins` table: an admin is an ordinary
HabitFlow account with one extra permission, so a separate table would have meant a second login
page, a second token shape and a second authentication concern for the same credentials. It is
granted by hand (`User.find_by(email: ...).update!(is_admin: true)`) and by **no endpoint** — the
only account that could call a promote action is already an admin, so an endpoint would be a
permanent privilege-escalation surface bought for nothing.

`is_admin` **is** a JWT claim, where `premium?` deliberately is not, and the difference is what each
is used for. The client reads `premium?` to decide whether a control is unlocked, so a stale claim
hands out a feature someone stopped paying for; it reads `is_admin` only to decide **which page to
route to** — `/login` sends an admin to `/admin/dashboard` and `next-app/proxy.ts` keeps them there
— and every `/admin/*` request re-checks the column, so a stale or forged claim buys a page that
answers 403.

An admin account is **not** a user of the app: it has no roles, goals or weekly plan, and the
frontend turns it back from every other route. That restriction is currently **client-side only** —
the user-facing endpoints would still answer an admin's bearer token. Nothing reaches them, because
nothing asks; if that should be enforced here too, it wants a shared guard on the fifteen
user-facing controllers rather than a check in each.

Three things about the payloads are load-bearing:

- **Every figure is anchored on a real timestamp** (`created_at`, `paid_at`, `tasks.updated_at`),
  never on a week boundary, so the rule that the server never derives "the current week" stays
  intact — `PremiumGated#free_history_floor` is still the only place it is broken. "Active" is
  therefore "touched a task in 30 days", not "signed in": the token lives seven days, so being
  signed in says nothing about the app having been opened.
- **Money is reported one currency at a time.** `payments.currency` is per row, so the currency with
  the largest paid total is the one the figures and the trend describe, and any other is listed
  beside it — a total that has added MYR to USD is not a number anyone can act on. The same rule
  applies per user in `lifetime_spend`.
- **The lists paginate with plain LIMIT/OFFSET and no gem**, capped at `MAX_PER_PAGE` so a client
  cannot turn a paginated endpoint back into an unpaginated one, ordered with a primary-key
  tie-break so two rows created in the same second cannot swap between pages, and clamped to the
  last page that exists rather than answering an empty table. Search escapes with
  `sanitize_sql_like`, or a `%` typed into the box would be a wildcard matching every account.

### Bans

`PATCH /admin/users/:id/ban` is the **one write on `AdminController`**, and the only endpoint in the
app that changes a row other than the caller's. Ban and unban are one action taking the state to end
in, because an unban is the same column going the other way; `banned` is required rather than
defaulted, since a missing parameter would cast to false and silently unban whoever the admin meant
to ban. An admin cannot ban themselves — the guard is on the whole class, so their next request
would be refused before reaching the action that undoes it.

`users.is_banned` is a column for the reason `is_admin` is: one more fact about an ordinary account,
not a second kind of account. It is **not** a JWT claim, for the reason `premium?` is not — a token
lives seven days in a cookie, and a ban that waited for it to expire would be a ban in name for most
of a week. So it is read off the column by `Authenticatable` on **every authenticated request**, not
only by the two login doors, and `authentication_controller_test.rb` pins that a token minted before
the ban stops working at once.

Two orderings are load-bearing:

- **The password is verified before the column is read.** Refusing on `is_banned` first would answer
  a banned *address* with the ban notice however wrong the password was, handing anyone who can type
  an email both the fact of the ban and the address to write to.
- **The Google callback refuses before the token write**, so a banned account's Google grant is not
  refreshed on the way to being turned away.

`GET /admin/users` takes `access=banned|active`, which narrows the **same scope the search does**
rather than replacing it. An unrecognised value shows every account, the way `payments` treats a
status it does not know: an empty table reads as a page that failed to load, which is the worse of
the two wrongs. `users.banned` on the overview is the count that motivates the filter, and is
deliberately not windowed like `new_recently` beside it — a ban is a standing state, not something
that happened in the last thirty days.

A refusal is **403 with `code: "banned"` in the body**, not a fourth status. 403 already means two
things here (not an administrator, and a checkout session belonging to somebody else) and the client
has to tell them apart, so `ApplicationController#render_banned` sends a code beside the status
along with the account's email and `ADMIN_CONTACT_EMAIL` — the frontend holds no copy of that
address. The OAuth road home has no body, so `redirect_banned` puts the same three facts in the
fragment, which is why `next-app` has one handler for all three doors a ban can be found at.
