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
- No GraphQL; plain REST-style JSON controllers.
- Currently very early-stage: one model (`User`, primary key `user_id`), one controller (`AuthenticationController` with empty `signup`/`login`/`callback` stubs), routes limited to `POST /signup`, `POST /login`, `GET /callback`.
- `users` schema already has Google OAuth/Calendar columns (`google_access_token`, `google_refresh_token`, `google_scope`, `google_uid`, `calendar_id`, etc.) — auth is being built around Google OAuth.
- CORS is currently disabled: `config/initializers/cors.rb` has the `Rack::Cors` block commented out, and the `rack-cors` gem is commented out in the Gemfile. Uncomment both when wiring up the frontend (`next-app`).
- Secrets use Rails encrypted credentials (`config/master.key` + `config/credentials.yml.enc`), not dotenv.
