class CreateWeeklySummaries < ActiveRecord::Migration[8.1]
  def change
    create_table :weekly_summaries, id: false do |t|
      t.primary_key :weekly_summary_id
      t.bigint :weekly_plan_id, null: false
      t.text :content, null: false
      # Which model wrote it. A summary is never regenerated, so without this a week summarised a
      # year ago is indistinguishable from one summarised today.
      t.string :model, null: false
      t.datetime :generated_at, null: false
      # No updated_at: a summary is written once and never changed, the same reason
      # goal_carryovers carries only created_at.
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # Business rule 10 -- at most one summary per weekly plan -- and what actually makes the
    # once-per-week guarantee true when two clicks race.
    add_index :weekly_summaries, :weekly_plan_id, unique: true
    add_foreign_key :weekly_summaries, :weekly_plans, column: :weekly_plan_id, primary_key: :weekly_plan_id
  end
end
