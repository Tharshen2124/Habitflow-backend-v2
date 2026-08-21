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
- CORS is enabled (`rack-cors` gem + `config/initializers/cors.rb`); the frontend at `next-app` calls this API for real, including in its Playwright suite.
- Secrets use Rails encrypted credentials (`config/master.key` + `config/credentials.yml.enc`), not dotenv.

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
