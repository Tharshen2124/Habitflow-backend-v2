# Join between a weekly plan and the standing Sharpen the Saw activities committed to that week.
# Sharpen the Saw activities are a per-user library that repeats verbatim week to week, so a week
# selects from them rather than owning its own copies the way goals do.
class WeeklyPlanStsActivity < ApplicationRecord
  self.primary_key = "weekly_plan_sts_id"

  belongs_to :weekly_plan, foreign_key: "weekly_plan_id", primary_key: "weekly_plan_id"
  belongs_to :sharpen_the_saw_activity, foreign_key: "sharpen_the_saw_activity_id",
                                        primary_key: "sharpen_the_saw_activity_id"

  validates :sharpen_the_saw_activity_id, uniqueness: { scope: :weekly_plan_id }
end
