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

  # Whether the work behind the goal actually got done, which is the only definition of "achieved"
  # in this app -- `goals.is_completed` is a leftover that no screen ever wrote, so every figure
  # built on it read zero. A goal is served by its tasks, and those are ticked off for real.
  #
  # Deliberately not vacuous: a goal nobody scheduled a single task for was not achieved by having
  # nothing to do. It reads as missed once its week has ended, the same as one left unfinished.
  scope :achieved, -> {
    where("EXISTS (SELECT 1 FROM tasks WHERE tasks.goal_id = goals.goal_id)")
      .where.not("EXISTS (SELECT 1 FROM tasks WHERE tasks.goal_id = goals.goal_id AND tasks.is_completed = false)")
  }

  def dropped?
    deleted_at.present?
  end
end
