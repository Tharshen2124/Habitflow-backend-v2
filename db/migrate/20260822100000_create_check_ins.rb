class CreateCheckIns < ActiveRecord::Migration[8.1]
  def change
    create_table :check_ins, id: false do |t|
      t.primary_key :check_in_id
      t.bigint :weekly_plan_id, null: false
      # Monday-indexed 0..6, the same indexing evening_reflections and tasks use. The week comes
      # from the plan, so there is no date column here that could fall out of step with
      # weekly_plans.start_date -- and the foreign key is what enforces the rule the client already
      # follows, that a check-in only happens on a week that was planned.
      t.integer :day_of_week, null: false
      # "completed" once the evening's tasks and reflection were saved, "skipped" when the prompt
      # was dismissed. Skipping is the fact only this table holds: a completed check-in always
      # leaves an evening_reflections row behind it, since the reflection is what unlocks Save.
      t.string :status, null: false
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # One check-in per day per week, so "has tonight been dealt with" is a lookup rather than a
    # scan, and a skip that later turns into a save updates the row instead of adding a second one.
    add_index :check_ins, [ :weekly_plan_id, :day_of_week ], unique: true
    add_foreign_key :check_ins, :weekly_plans, column: :weekly_plan_id, primary_key: :weekly_plan_id
  end
end
