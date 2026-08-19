class Task < ApplicationRecord
  self.primary_key = "task_id"

  belongs_to :user, foreign_key: "user_id", primary_key: "user_id"
  belongs_to :goal, foreign_key: "goal_id", primary_key: "goal_id", optional: true
  belongs_to :sharpen_the_saw_activity, foreign_key: "sharpen_the_saw_activity_id",
                                         primary_key: "sharpen_the_saw_activity_id", optional: true
  belongs_to :weekly_plan, foreign_key: "weekly_plan_id", primary_key: "weekly_plan_id"

  validates :task_name, presence: true
  validates :day_of_week, presence: true, inclusion: { in: 0..6 }
  validates :start_time, presence: true
  validates :end_time, presence: true
  validate :end_time_after_start_time
  validate :fixed_appointment_has_no_priority_or_links
  validate :goal_belongs_to_the_same_weekly_plan

  private

  def end_time_after_start_time
    return if start_time.blank? || end_time.blank?
    errors.add(:end_time, "must be after start time") if end_time <= start_time
  end

  def fixed_appointment_has_no_priority_or_links
    return unless is_fixed_appointment

    errors.add(:goal_id, "must be blank for a fixed appointment") if goal_id.present?
    errors.add(:sharpen_the_saw_activity_id, "must be blank for a fixed appointment") if sharpen_the_saw_activity_id.present?
    errors.add(:is_daily_priority, "cannot be set for a fixed appointment") if is_daily_priority
    errors.add(:daily_priority_date, "must be blank for a fixed appointment") if daily_priority_date.present?
  end

  # A week's tasks can only serve that week's goals. Without this, a user who crosses a Monday
  # part-way through onboarding would silently schedule this week's tasks against last week's goals.
  def goal_belongs_to_the_same_weekly_plan
    return if goal.blank? || weekly_plan_id.blank?

    errors.add(:goal_id, "must belong to the same weekly plan") if goal.weekly_plan_id != weekly_plan_id
  end
end
