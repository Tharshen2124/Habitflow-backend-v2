class CreateWeeklyPlans < ActiveRecord::Migration[8.1]
  def change
    create_table :weekly_plans, id: false do |t|
      t.primary_key :weekly_plan_id
      t.bigint :user_id, null: false
      t.date :start_date, null: false # always a Monday, supplied by the client
      t.date :end_date, null: false # start_date + 6
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # One plan per user per week. This is what makes WeeklyPlan.for! safe against a double submit.
    add_index :weekly_plans, [ :user_id, :start_date ], unique: true
    add_foreign_key :weekly_plans, :users, column: :user_id, primary_key: :user_id
  end
end
