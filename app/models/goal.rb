class Goal < ApplicationRecord
  self.primary_key = "goal_id"

  belongs_to :role, foreign_key: "role_id", primary_key: "role_id"
  belongs_to :weekly_plan, foreign_key: "weekly_plan_id", primary_key: "weekly_plan_id"

  # No `dependent:` — a completed task stays on its week's calendar and keeps counting even after
  # its goal is dropped. ArchiveGoal removes only the tasks that were never done.
  has_many :tasks, foreign_key: "goal_id", primary_key: "goal_id"

  # Lineage across weeks. `carried_to` is the link to next week's continuation of this goal;
  # `carried_from` is the link back to the goal this one continues.
  has_one :carried_to, class_name: "GoalCarryover",
          foreign_key: "source_goal_id", primary_key: "goal_id"
  has_one :carried_from, class_name: "GoalCarryover",
          foreign_key: "destination_goal_id", primary_key: "goal_id"

  validates :description, presence: true

  scope :active, -> { where(deleted_at: nil) }
  scope :dropped, -> { where.not(deleted_at: nil) }

  def dropped?
    deleted_at.present?
  end

  # How this goal resolved. `as_of` is the caller's local date, for the same reason week_start is
  # client-supplied everywhere else: the server stores no timezone for the user, so it must not
  # decide on its own whether a week has ended.
  def outcome(as_of: Date.current)
    return :dropped if dropped?
    return :achieved if is_completed

    weekly_plan.end_date < as_of ? :missed : :open
  end
end
