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

ActiveRecord::Schema[8.1].define(version: 2026_08_19_101800) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "goals", primary_key: "goal_id", force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "description", null: false
    t.boolean "is_completed", default: false, null: false
    t.boolean "is_weekly_priority", default: false, null: false
    t.bigint "role_id", null: false
    t.bigint "weekly_plan_id", null: false
    t.index ["role_id"], name: "index_goals_on_role_id"
    t.index ["weekly_plan_id"], name: "index_goals_on_weekly_plan_id"
  end

  create_table "roles", primary_key: "role_id", force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "icon_id"
    t.string "role_name", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_roles_on_user_id"
  end

  create_table "sharpen_the_saw_activities", primary_key: "sharpen_the_saw_activity_id", force: :cascade do |t|
    t.string "activity_description", null: false
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "dimension", null: false
    t.boolean "is_deleted", default: false, null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "is_deleted"], name: "index_sharpen_the_saw_activities_on_user_id_and_is_deleted"
  end

  create_table "tasks", primary_key: "task_id", force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.date "daily_priority_date"
    t.integer "day_of_week", null: false
    t.string "description"
    t.time "end_time", null: false
    t.bigint "goal_id"
    t.string "google_calendar_event_id"
    t.boolean "is_completed", default: false, null: false
    t.boolean "is_daily_priority", default: false, null: false
    t.boolean "is_fixed_appointment", default: false, null: false
    t.bigint "sharpen_the_saw_activity_id"
    t.time "start_time", null: false
    t.string "sync_status"
    t.string "task_name", null: false
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.bigint "user_id", null: false
    t.bigint "weekly_plan_id", null: false
    t.index ["goal_id"], name: "index_tasks_on_goal_id"
    t.index ["sharpen_the_saw_activity_id"], name: "index_tasks_on_sharpen_the_saw_activity_id"
    t.index ["user_id"], name: "index_tasks_on_user_id"
    t.index ["weekly_plan_id", "day_of_week"], name: "index_tasks_on_weekly_plan_id_and_day_of_week"
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

  create_table "weekly_plan_sts_activities", primary_key: "weekly_plan_sts_id", force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.bigint "sharpen_the_saw_activity_id", null: false
    t.bigint "weekly_plan_id", null: false
    t.index ["sharpen_the_saw_activity_id"], name: "index_weekly_plan_sts_on_activity"
    t.index ["weekly_plan_id", "sharpen_the_saw_activity_id"], name: "index_weekly_plan_sts_on_plan_and_activity", unique: true
  end

  create_table "weekly_plans", primary_key: "weekly_plan_id", force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.date "end_date", null: false
    t.date "start_date", null: false
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "start_date"], name: "index_weekly_plans_on_user_id_and_start_date", unique: true
  end

  add_foreign_key "goals", "roles", primary_key: "role_id"
  add_foreign_key "goals", "weekly_plans", primary_key: "weekly_plan_id"
  add_foreign_key "roles", "users", primary_key: "user_id"
  add_foreign_key "sharpen_the_saw_activities", "users", primary_key: "user_id"
  add_foreign_key "tasks", "goals", primary_key: "goal_id"
  add_foreign_key "tasks", "sharpen_the_saw_activities", primary_key: "sharpen_the_saw_activity_id"
  add_foreign_key "tasks", "users", primary_key: "user_id"
  add_foreign_key "tasks", "weekly_plans", primary_key: "weekly_plan_id"
  add_foreign_key "weekly_plan_sts_activities", "sharpen_the_saw_activities", primary_key: "sharpen_the_saw_activity_id"
  add_foreign_key "weekly_plan_sts_activities", "weekly_plans", primary_key: "weekly_plan_id"
  add_foreign_key "weekly_plans", "users", primary_key: "user_id"
end
