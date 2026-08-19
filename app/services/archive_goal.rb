# Drops a goal from the week it belongs to, without erasing what the week recorded.
#
# The goal row stays and keeps its `role_id`, so /history and /analytics can still resolve every
# task it owned back to a role. Only the tasks that were never done are removed -- a completed task
# is a fact about that week and stays on the calendar and in the totals. Removing it would let a
# user raise their own completion rate by deleting the goals they were failing.
class ArchiveGoal
  def self.preview(goal)
    counts = goal.tasks.group(:is_completed).count

    {
      goals: 1,
      incomplete_tasks: counts.fetch(false, 0),
      completed_tasks: counts.fetch(true, 0)
    }
  end

  def self.call(goal, now: Time.current)
    preview(goal).tap do
      Goal.transaction do
        goal.tasks.where(is_completed: false).destroy_all
        goal.update!(deleted_at: now)
      end
    end
  end

  def self.restore(goal)
    goal.update!(deleted_at: nil)
    goal
  end
end
