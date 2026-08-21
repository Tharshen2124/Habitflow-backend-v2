class CreateEveningReflections < ActiveRecord::Migration[8.1]
  def change
    create_table :evening_reflections, id: false do |t|
      t.primary_key :evening_reflection_id
      t.bigint :weekly_plan_id, null: false
      # Monday-indexed 0..6, the same indexing tasks.day_of_week uses. The week itself comes from
      # the plan, so there is deliberately no date column here that could drift out of agreement
      # with weekly_plans.start_date.
      t.integer :day_of_week, null: false
      t.text :content, null: false
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # One reflection per day per week. This is also what makes the weekly summary's precondition a
    # plain count: seven rows can only mean seven distinct days.
    add_index :evening_reflections, [ :weekly_plan_id, :day_of_week ], unique: true
    add_foreign_key :evening_reflections, :weekly_plans, column: :weekly_plan_id, primary_key: :weekly_plan_id
  end
end
