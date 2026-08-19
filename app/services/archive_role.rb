# Retires a role from future planning without touching the weeks it already appears in.
#
# Only the given week's live goals are dropped alongside it. Goals in earlier weeks are history and
# are left exactly as they are -- archiving a role is a statement about what you plan next, not a
# revision of what you did.
class ArchiveRole
  def self.preview(role, weekly_plan)
    live_goals(role, weekly_plan).reduce(empty) do |totals, goal|
      merge(totals, ArchiveGoal.preview(goal))
    end
  end

  def self.call(role, weekly_plan, now: Time.current)
    Role.transaction do
      live_goals(role, weekly_plan).reduce(empty) { |totals, goal|
        merge(totals, ArchiveGoal.call(goal, now: now))
      }.tap { role.update!(deleted_at: now) }
    end
  end

  # Restoring brings the role back for future planning only. Goals dropped when it was archived
  # stay dropped: their week has moved on, and their unfinished tasks are already gone.
  def self.restore(role)
    role.update!(deleted_at: nil)
    role
  end

  def self.live_goals(role, weekly_plan)
    return Goal.none if weekly_plan.nil?

    role.goals.active.where(weekly_plan_id: weekly_plan.weekly_plan_id)
  end

  def self.empty
    { goals: 0, incomplete_tasks: 0, completed_tasks: 0 }
  end
  private_class_method :empty

  def self.merge(totals, counts)
    totals.merge(counts) { |_key, a, b| a + b }
  end
  private_class_method :merge
end
