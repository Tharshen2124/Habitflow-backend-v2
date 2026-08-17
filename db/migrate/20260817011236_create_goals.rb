class CreateGoals < ActiveRecord::Migration[8.1]
  def change
    create_table :goals, id: false do |t|
      t.primary_key :goal_id
      t.bigint :role_id, null: false
      t.bigint :weekly_plan_id
      t.string :description, null: false
      t.boolean :is_completed, default: false, null: false
      t.boolean :is_weekly_priority, default: false, null: false
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :goals, :role_id
    add_foreign_key :goals, :roles, column: :role_id, primary_key: :role_id
  end
end
