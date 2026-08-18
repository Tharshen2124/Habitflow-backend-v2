class CreateTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :tasks, id: false do |t|
      t.primary_key :task_id
      t.bigint :user_id, null: false
      t.bigint :goal_id
      t.bigint :sharpen_the_saw_activity_id
      t.bigint :weekly_plan_id
      t.string :task_name, null: false
      t.string :description
      t.boolean :is_fixed_appointment, null: false, default: false
      t.integer :day_of_week, null: false # 0 = Monday .. 6 = Sunday, matches frontend dayIndex
      t.time :start_time, null: false
      t.time :end_time, null: false
      t.boolean :is_daily_priority, null: false, default: false
      t.boolean :is_completed, null: false, default: false
      t.date :daily_priority_date
      t.string :google_calendar_event_id
      t.string :sync_status
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :tasks, :user_id
    add_index :tasks, :goal_id
    add_index :tasks, :sharpen_the_saw_activity_id
    add_foreign_key :tasks, :users, column: :user_id, primary_key: :user_id
    add_foreign_key :tasks, :goals, column: :goal_id, primary_key: :goal_id
    add_foreign_key :tasks, :sharpen_the_saw_activities, column: :sharpen_the_saw_activity_id, primary_key: :sharpen_the_saw_activity_id
  end
end
