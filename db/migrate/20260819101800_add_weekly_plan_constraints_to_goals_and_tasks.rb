class AddWeeklyPlanConstraintsToGoalsAndTasks < ActiveRecord::Migration[8.1]
  def change
    add_index :goals, :weekly_plan_id
    # day_of_week is only meaningful relative to a plan's start_date, so the two are always read
    # together when building a week's calendar.
    add_index :tasks, [ :weekly_plan_id, :day_of_week ]

    add_foreign_key :goals, :weekly_plans, column: :weekly_plan_id, primary_key: :weekly_plan_id
    add_foreign_key :tasks, :weekly_plans, column: :weekly_plan_id, primary_key: :weekly_plan_id

    change_column_null :goals, :weekly_plan_id, false
    change_column_null :tasks, :weekly_plan_id, false
  end
end
