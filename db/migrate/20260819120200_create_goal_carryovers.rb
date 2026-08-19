class CreateGoalCarryovers < ActiveRecord::Migration[8.1]
  def change
    # Goals are week-owned copies, so continuing one into the next week means creating a new goal
    # and recording the link. The source and destination weeks are deliberately not stored: both
    # are reachable through the goals themselves, and duplicating them lets a row contradict the
    # goals it points at.
    create_table :goal_carryovers, id: false do |t|
      t.primary_key :goal_carryover_id
      t.bigint :source_goal_id, null: false
      t.bigint :destination_goal_id, null: false
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # Unique on both ends: a goal is carried forward at most once and continues at most one
    # predecessor, which makes a lineage a strict chain rather than a tree.
    add_index :goal_carryovers, :source_goal_id, unique: true
    add_index :goal_carryovers, :destination_goal_id, unique: true

    add_foreign_key :goal_carryovers, :goals, column: :source_goal_id, primary_key: :goal_id
    add_foreign_key :goal_carryovers, :goals, column: :destination_goal_id, primary_key: :goal_id
  end
end
