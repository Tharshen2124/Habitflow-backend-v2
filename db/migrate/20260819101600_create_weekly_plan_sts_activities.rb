class CreateWeeklyPlanStsActivities < ActiveRecord::Migration[8.1]
  def change
    create_table :weekly_plan_sts_activities, id: false do |t|
      t.primary_key :weekly_plan_sts_id
      t.bigint :weekly_plan_id, null: false
      t.bigint :sharpen_the_saw_activity_id, null: false
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # Index names are given explicitly: the generated ones exceed PostgreSQL's 63-char limit.
    add_index :weekly_plan_sts_activities, [ :weekly_plan_id, :sharpen_the_saw_activity_id ],
              unique: true, name: "index_weekly_plan_sts_on_plan_and_activity"
    add_index :weekly_plan_sts_activities, :sharpen_the_saw_activity_id,
              name: "index_weekly_plan_sts_on_activity"

    add_foreign_key :weekly_plan_sts_activities, :weekly_plans,
                    column: :weekly_plan_id, primary_key: :weekly_plan_id
    add_foreign_key :weekly_plan_sts_activities, :sharpen_the_saw_activities,
                    column: :sharpen_the_saw_activity_id, primary_key: :sharpen_the_saw_activity_id
  end
end
