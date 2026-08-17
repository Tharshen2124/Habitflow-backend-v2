# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_17_011236) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "goals", primary_key: "goal_id", force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "description", null: false
    t.boolean "is_completed", default: false, null: false
    t.boolean "is_weekly_priority", default: false, null: false
    t.bigint "role_id", null: false
    t.bigint "weekly_plan_id"
    t.index ["role_id"], name: "index_goals_on_role_id"
  end

  create_table "roles", primary_key: "role_id", force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "icon_id"
    t.string "role_name", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_roles_on_user_id"
  end

  create_table "users", primary_key: "user_id", force: :cascade do |t|
    t.string "calendar_id"
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "email", null: false
    t.boolean "email_notifications_enabled", default: true, null: false
    t.string "export_preference"
    t.string "google_access_token"
    t.string "google_refresh_token"
    t.string "google_scope"
    t.datetime "google_token_expires_at"
    t.string "google_uid"
    t.boolean "is_onboarded", default: false, null: false
    t.string "password_digest"
    t.string "username", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true
    t.index ["google_uid"], name: "index_users_on_google_uid", unique: true
    t.index ["username"], name: "index_users_on_username", unique: true
  end

  add_foreign_key "goals", "roles", primary_key: "role_id"
  add_foreign_key "roles", "users", primary_key: "user_id"
end
