# The figures behind /analytics: one row per planned week, counts only.
#
# Like history#weeks this reasons about a range rather than a single week, so it is not week-scoped
# and looking creates nothing. And like /history it reads a past week *as it was recorded* -- an
# archived role still owned the tasks it owned, and ERD_businnes_rules.md is explicit that nothing
# a user planned is hard-deleted precisely so this controller can resolve `task -> goal -> role`
# for a week whose role has since been retired.
#
# Everything here is a count. The four cards on the page turn counts into percentages themselves,
# for the same reason history#goal_json ships parts rather than an outcome: a ratio is cheap to
# compute and a client that owns it can re-slice a range without another round trip.
class AnalyticsController < ApplicationController
  include Authenticatable
  include WeekScoped

  def show
    range = parse_week_range
    return if range.nil?

    from, to = range

    render json: { weeks: week_analytics(from, to) }
  end

  private

  # Grouped counts across every plan in the range, then a lookup per week -- never a query per
  # week. A year of weeks is the same eleven queries as one.
  def week_analytics(from, to)
    plans = current_user.weekly_plans.where(start_date: from..to).order(start_date: :desc)
    ids = plans.map(&:weekly_plan_id)

    roles = role_counts(ids)
    dimensions = dimension_counts(ids)
    priorities = daily_priority_counts(ids)
    goals = goal_counts(ids)

    plans.map do |plan|
      id = plan.weekly_plan_id
      {
        week_start: plan.start_date.iso8601,
        end_date: plan.end_date.iso8601,
        dimensions: dimensions.fetch(id, []),
        roles: roles.fetch(id, []),
        daily_priorities: priorities.fetch(id, []),
        goals: goals.fetch(id, { achieved: 0, total: 0, dropped: 0 })
      }
    end
  end

  # Tasks per role, resolved through the goal. Joining the goal also excludes fixed appointments
  # for free: Task#fixed_appointment_has_no_priority_or_links forbids one from carrying a goal.
  #
  # `role_name` and `color_id` are looked up unscoped, so a week planned under a role the user has
  # since archived still reports under its own name rather than falling out of the table.
  def role_counts(ids)
    tasks = Task.where(weekly_plan_id: ids).where.not(goal_id: nil).joins(:goal)
    totals = tasks.group("tasks.weekly_plan_id", "goals.role_id").count
    completed = tasks.where(is_completed: true).group("tasks.weekly_plan_id", "goals.role_id").count

    roles = Role.where(role_id: totals.keys.map(&:last).uniq).index_by(&:role_id)

    totals.group_by { |(plan_id, _role_id), _n| plan_id }.transform_values do |entries|
      entries.filter_map do |(plan_id, role_id), total|
        role = roles[role_id]
        next if role.nil?

        {
          role_id: role.role_id,
          name: role.role_name,
          color_id: role.color_id,
          completed: completed.fetch([ plan_id, role_id ], 0),
          total: total
        }
      end.sort_by { |r| r[:role_id] }
    end
  end

  # The renewal figure the radar draws: of the tasks scheduled against an activity in a dimension,
  # how many were done. Only dimensions the week actually scheduled something for are sent -- the
  # four fixed dimensions live in the frontend (lib/sharpen-the-saw-dimensions.ts), so it fills in
  # the ones with nothing to report rather than the server shipping zeroes for them.
  #
  # `dimension` stays the raw stored string, the same division of labour as history#task_json:
  # display names and palettes are the client's.
  def dimension_counts(ids)
    tasks = Task.where(weekly_plan_id: ids).joins(:sharpen_the_saw_activity)
    column = "sharpen_the_saw_activities.dimension"
    totals = tasks.group("tasks.weekly_plan_id", column).count
    completed = tasks.where(is_completed: true).group("tasks.weekly_plan_id", column).count

    totals.group_by { |(plan_id, _dimension), _n| plan_id }.transform_values do |entries|
      entries.map do |(plan_id, dimension), total|
        {
          dimension: dimension,
          completed: completed.fetch([ plan_id, dimension ], 0),
          total: total
        }
      end.sort_by { |d| d[:dimension] }
    end
  end

  # Starred priorities per day. No fixed-appointment filter is needed -- the same validation that
  # keeps a goal off a fixed appointment keeps `is_daily_priority` off one. Days with nothing
  # starred are absent rather than zero, and the client expands the week to seven rows.
  def daily_priority_counts(ids)
    tasks = Task.where(weekly_plan_id: ids, is_daily_priority: true)
    totals = tasks.group(:weekly_plan_id, :day_of_week).count
    completed = tasks.where(is_completed: true).group(:weekly_plan_id, :day_of_week).count

    totals.group_by { |(plan_id, _day), _n| plan_id }.transform_values do |entries|
      entries.map do |(plan_id, day), total|
        {
          day_of_week: day,
          completed: completed.fetch([ plan_id, day ], 0),
          total: total
        }
      end.sort_by { |d| d[:day_of_week] }
    end
  end

  # Goals are counted `.active`, so a goal the user dropped mid-week cannot sit in the denominator
  # -- pruning one would otherwise raise the percentage. It is reported beside the ratio instead,
  # the same rule history#week_summaries follows and the one ERD_businnes_rules.md states: a
  # dropped goal is neither a failure nor a quiet improvement.
  def goal_counts(ids)
    goals = Goal.where(weekly_plan_id: ids)
    totals = goals.active.group(:weekly_plan_id).count
    achieved = goals.active.where(is_completed: true).group(:weekly_plan_id).count
    dropped = goals.dropped.group(:weekly_plan_id).count

    ids.index_with do |id|
      {
        achieved: achieved.fetch(id, 0),
        total: totals.fetch(id, 0),
        dropped: dropped.fetch(id, 0)
      }
    end
  end
end
