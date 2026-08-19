# Stamps every pre-existing goal and task onto a weekly plan so the NOT NULL constraints in the
# following migration can be applied.
#
# The model classes are declared locally rather than reused from app/models: those keep changing,
# and a migration has to keep working against the schema as it was at this point in history.
class BackfillWeeklyPlans < ActiveRecord::Migration[8.1]
  class User < ApplicationRecord
    self.table_name = "users"
    self.primary_key = "user_id"
  end

  class Role < ApplicationRecord
    self.table_name = "roles"
    self.primary_key = "role_id"
  end

  class Goal < ApplicationRecord
    self.table_name = "goals"
    self.primary_key = "goal_id"
  end

  class Task < ApplicationRecord
    self.table_name = "tasks"
    self.primary_key = "task_id"
  end

  class SharpenTheSawActivity < ApplicationRecord
    self.table_name = "sharpen_the_saw_activities"
    self.primary_key = "sharpen_the_saw_activity_id"
  end

  class WeeklyPlan < ApplicationRecord
    self.table_name = "weekly_plans"
    self.primary_key = "weekly_plan_id"
  end

  class WeeklyPlanStsActivity < ApplicationRecord
    self.table_name = "weekly_plan_sts_activities"
    self.primary_key = "weekly_plan_sts_id"
  end

  def up
    User.find_each do |user|
      role_ids = Role.where(user_id: user.user_id).pluck(:role_id)
      goals = Goal.where(role_id: role_ids, weekly_plan_id: nil)
      tasks = Task.where(user_id: user.user_id, weekly_plan_id: nil)

      earliest = [ goals.minimum(:created_at), tasks.minimum(:created_at) ].compact.min
      next if earliest.nil?

      # One plan per user, anchored on the Monday of their earliest orphaned record — not one plan
      # per calendar week. A single plan preserves the goal/task same-plan invariant that the new
      # Task validation enforces, which matters more here than perfect date fidelity.
      start_date = earliest.to_date.beginning_of_week(:monday)
      plan = WeeklyPlan.find_or_create_by!(user_id: user.user_id, start_date: start_date) do |p|
        p.end_date = start_date + 6
      end

      goals.update_all(weekly_plan_id: plan.weekly_plan_id)
      tasks.update_all(weekly_plan_id: plan.weekly_plan_id)

      # Onboarding commits every activity the user defined to the week they defined it in.
      SharpenTheSawActivity.where(user_id: user.user_id, is_deleted: false).find_each do |activity|
        WeeklyPlanStsActivity.find_or_create_by!(
          weekly_plan_id: plan.weekly_plan_id,
          sharpen_the_saw_activity_id: activity.sharpen_the_saw_activity_id
        )
      end
    end
  end

  def down
    Goal.update_all(weekly_plan_id: nil)
    Task.update_all(weekly_plan_id: nil)
    WeeklyPlanStsActivity.delete_all
    WeeklyPlan.delete_all
  end
end
