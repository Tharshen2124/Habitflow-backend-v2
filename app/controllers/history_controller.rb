# Reading a week that has already happened.
#
# Every other read in this app is a planning surface, and planning surfaces read `.active`: an
# archived role and a dropped goal are gone from the weeks still to come. /history is the other
# half of that rule -- it reads the week *as it was recorded*, soft-deleted rows and all, which is
# the whole reason nothing a user has planned is ever hard-deleted (ERD_businnes_rules.md).
#
# So this controller cannot be assembled from /roles and /sharpen-the-saw-activities. Those filter
# exactly what a past week most needs to keep.
class HistoryController < ApplicationController
  include Authenticatable
  include WeekScoped

  # A read, so `find_weekly_plan` rather than `set_weekly_plan`: looking at a week must never file
  # a plan row for it. A plan row existing is the client's only answer to "is this week planned?",
  # and /weekly-plan picks which week to offer from that answer.
  before_action :find_weekly_plan, only: [ :show ]


  # One past week in full: its goals with the roles they belong to, the renewal activities it
  # committed to, and its schedule. A week the user never planned answers `null` -- normal, not an
  # error, the same way weekly_plans#show does.
  def show
    return render json: { week: nil } if @weekly_plan.nil?

    render json: { week: week_json(@weekly_plan) }
  end

  # The sidebar's week strip: counts per week, never content. The detail panel fetches one week at
  # a time, so shipping every week's goals just to label a list of dates would be the whole history
  # on load. Deliberately not week-scoped -- it reasons about a range, and looking creates nothing.
  def weeks
    range = parse_week_range
    return if range.nil?

    from, to = range

    render json: { weeks: week_summaries(from, to) }
  end

  private

  def week_summaries(from, to)
    plans = current_user.weekly_plans.where(start_date: from..to).order(start_date: :desc)
    plan_ids = plans.map(&:weekly_plan_id)

    # Grouped counts rather than a count per plan: eight weeks in the strip would otherwise be
    # thirty-two queries. Goals are counted `.active` -- a goal the user dropped is reported in the
    # detail panel but must not sit in the denominator, or pruning one would raise the percentage.
    goals = Goal.where(weekly_plan_id: plan_ids).active
    goal_counts = goals.group(:weekly_plan_id).count
    goal_achieved = goals.where(is_completed: true).group(:weekly_plan_id).count

    # Scheduled tasks only, so the figure lines up with the fixed-appointment count beside it.
    tasks = Task.where(weekly_plan_id: plan_ids, is_fixed_appointment: false)
    task_counts = tasks.group(:weekly_plan_id).count
    task_completed = tasks.where(is_completed: true).group(:weekly_plan_id).count

    activity_counts = WeeklyPlanStsActivity.where(weekly_plan_id: plan_ids)
                                           .group(:weekly_plan_id).count

    plans.map do |plan|
      id = plan.weekly_plan_id
      {
        week_start: plan.start_date.iso8601,
        goal_count: goal_counts.fetch(id, 0),
        goals_achieved: goal_achieved.fetch(id, 0),
        task_count: task_counts.fetch(id, 0),
        tasks_completed: task_completed.fetch(id, 0),
        activity_count: activity_counts.fetch(id, 0)
      }
    end
  end

  def week_json(plan)
    goals = plan.goals.includes(:role, :carried_to).order(:goal_id)
    lineage = lineage_depths(goals)

    {
      week_start: plan.start_date.iso8601,
      end_date: plan.end_date.iso8601,
      goals: goals.map { |g| goal_json(g, lineage) },
      activities: plan.sharpen_the_saw_activities.order(:sharpen_the_saw_activity_id)
                      .map { |a| activity_json(a) },
      tasks: plan.tasks.includes(:sharpen_the_saw_activity, goal: :role)
                 .order(:day_of_week, :start_time).map { |t| task_json(t) }
    }
  end

  # No `.active` on the goals, and no `outcome` on the way out.
  #
  # Goal#outcome needs to know whether the week has ended, and that is a client fact everywhere in
  # this app -- the server stores no timezone, which is why every `week_start` arrives from the
  # browser. So the parts go over the wire and the client composes the outcome, the same division of
  # labour as `link_kind`/`link_text` below.
  def goal_json(goal, lineage)
    {
      goal_id: goal.goal_id,
      text: goal.description,
      is_weekly_priority: goal.is_weekly_priority,
      is_completed: goal.is_completed,
      is_dropped: goal.dropped?,
      # How long this goal has been running, and whether it outlived the week. Together they are
      # what separates "given up on" from "still going": a goal unfinished in a week it was carried
      # out of is not the failure a bare cross makes it look like.
      week_index: lineage.fetch(goal.goal_id, 1),
      is_carried_forward: goal.carried_to.present?,
      role: {
        role_id: goal.role.role_id,
        name: goal.role.role_name,
        color_id: goal.role.color_id,
        icon_id: goal.role.icon_id,
        is_archived: goal.role.archived?
      }
    }
  end

  # How many weeks each of this week's goals has been running: 1 for one begun here, 2 for one
  # carried in once, and so on.
  #
  # Goals are week-owned copies, so a lineage is a chain of `goal_carryovers` rows rather than a
  # column to read. The whole chain is loaded in one query and walked in memory -- a goal on its
  # fifth week would otherwise be four more round trips, once per goal on the panel.
  def lineage_depths(goals)
    parents = carryover_parents

    goals.to_h do |goal|
      depth = 1
      current = goal.goal_id
      # `GoalCarryover#points_forward` rejects a link that does not move strictly forwards in time,
      # so this walk terminates. `seen` guards only against a row written before that validation.
      seen = Set.new([ current ])

      while (parent = parents[current]) && seen.add?(parent)
        depth += 1
        current = parent
      end

      [ goal.goal_id, depth ]
    end
  end

  # destination -> source for every carryover this user owns. User-wide rather than week-wide: a
  # chain reaches back past whichever week is on screen.
  def carryover_parents
    GoalCarryover.joins(destination_goal: :weekly_plan)
                 .where(weekly_plans: { user_id: current_user.user_id })
                 .pluck("goal_carryovers.destination_goal_id", "goal_carryovers.source_goal_id")
                 .to_h
  end

  # Also unscoped. An activity the user has since deleted still happened in this week, and the join
  # row recording that is not soft-deleted -- so the week can say so, flagged rather than hidden.
  def activity_json(activity)
    {
      sharpen_the_saw_activity_id: activity.sharpen_the_saw_activity_id,
      dimension: activity.dimension,
      activity_description: activity.activity_description,
      is_deleted: activity.deleted_at.present?
    }
  end

  # weekly_plans#task_json plus `role_color_id`, which the schedule needs to tint a chip in its
  # role's colour. `dimension` stays the raw stored string: the display names for the four
  # dimensions live in the frontend, so it composes the final label.
  def task_json(task)
    {
      task_id: task.task_id,
      title: task.task_name,
      description: task.description,
      day_of_week: task.day_of_week,
      start_time: task.start_time.strftime("%H:%M"),
      end_time: task.end_time.strftime("%H:%M"),
      is_fixed_appointment: task.is_fixed_appointment,
      is_daily_priority: task.is_daily_priority,
      is_completed: task.is_completed,
      link_kind: link_kind(task),
      link_text: task.goal&.description || task.sharpen_the_saw_activity&.activity_description,
      role_name: task.goal&.role&.role_name,
      role_color_id: task.goal&.role&.color_id,
      dimension: task.sharpen_the_saw_activity&.dimension
    }
  end

  def link_kind(task)
    return "goal" if task.goal_id.present?
    return "activity" if task.sharpen_the_saw_activity_id.present?

    nil
  end
end
