# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# A paid account for the Playwright suite to log in as.
#
# Every other e2e account is signed up through the real UI, which is the only way this app makes
# one -- and that account is always Free, because becoming Premium means going through Stripe. Most
# paid paths are covered by flipping the tier flag on the response as it goes past
# (`grantPremium` in tests/e2e/helpers.ts), but the AI summary cannot be: it is written **once per
# week and never regenerated**, so the assertion that it is stored and unrepeatable needs a real
# account against a real backend.
#
# Local only. Nothing creates or promotes an account like this at runtime -- there is no route or
# action that grants a subscription outside Stripe's webhook -- so this file is the whole of it, and
# `db/seeds.rb` is not run in production.
if Rails.env.local?
  user = User.find_or_initialize_by(email: "e2e-premium@example.com")
  user.assign_attributes(
    username: "e2e_premium",
    password: "password123",
    is_onboarded: true,
    subscription_status: "active",
    subscription_period_end: 1.year.from_now
  )
  user.save!
  puts "Seeded premium e2e account: #{user.email}"
end

# An administrator for the admin dashboard.
#
# Same shape as the account above and for the same reason: nothing at runtime grants this flag --
# there is deliberately no "promote" endpoint, since the only account that could call one is already
# an admin -- so a local database has no other way to get one. `db/seeds.rb` is not run in
# production, where the flag is set by hand:
#
#   User.find_by(email: "you@example.com").update!(is_admin: true)
if Rails.env.local?
  admin = User.find_or_initialize_by(email: "admin@example.com")
  admin.assign_attributes(
    username: "admin",
    password: "password123",
    is_onboarded: true,
    is_admin: true
  )
  admin.save!
  puts "Seeded admin account: #{admin.email}"
end
