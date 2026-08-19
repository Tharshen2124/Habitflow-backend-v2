class AddArchivingToGoals < ActiveRecord::Migration[8.1]
  def change
    # A dropped goal stays in its week: its completed tasks still count, and the week's goal
    # outcomes read achieved / missed / dropped off this column plus is_completed.
    add_column :goals, :deleted_at, :datetime
    add_column :goals, :updated_at, :datetime, null: false, default: -> { "CURRENT_TIMESTAMP" }

    # Every planning surface asks for one week's live goals.
    add_index :goals, [ :weekly_plan_id, :deleted_at ]
  end
end
