# Links a goal to its continuation in a later week. Goals are week-owned copies, so carrying one
# forward creates a new goal and records this link rather than reusing the original row.
#
# These rows are never deleted, including when the destination goal is later dropped: "carried for
# three weeks, then given up on" is exactly what the chain is there to record.
class GoalCarryover < ApplicationRecord
  self.primary_key = "goal_carryover_id"

  belongs_to :source_goal, class_name: "Goal",
             foreign_key: "source_goal_id", primary_key: "goal_id"
  belongs_to :destination_goal, class_name: "Goal",
             foreign_key: "destination_goal_id", primary_key: "goal_id"

  # One link at each end, so a lineage is a strict chain: a goal is carried forward at most once
  # and continues at most one predecessor. Splitting and merging are deliberately not supported.
  validates :source_goal_id, uniqueness: true
  validates :destination_goal_id, uniqueness: true

  validate :points_forward

  private

  # Without this a chain can loop back on itself and any walk of it never terminates.
  def points_forward
    if source_goal_id.present? && source_goal_id == destination_goal_id
      errors.add(:destination_goal_id, "must be a different goal")
      return
    end

    return if source_goal.blank? || destination_goal.blank?

    if destination_goal.weekly_plan.start_date <= source_goal.weekly_plan.start_date
      errors.add(:destination_goal_id, "must belong to a later week than the source goal")
    end
  end
end
