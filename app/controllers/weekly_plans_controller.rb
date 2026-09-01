class WeeklyPlansController < ApplicationController
  include Authenticatable
  include WeekScoped

  before_action :find_weekly_plan, only: [ :show, :sharpen_the_saw ]
  before_action :set_weekly_plan, only: [ :update_sharpen_the_saw ]

  # Read-only view of one week, for the dashboard. A null plan is a normal answer, not an error:
  # it is how the client knows the week has not been planned yet.
  # `eod_time` rides along because the dashboard cannot decide whether to prompt for the check-in
  # until it knows both the time and whether the week is planned, and two requests to answer one
  # question would mean either delaying the prompt or showing it and taking it back.
  def show
    return render json: { weekly_plan: nil, eod_time: eod_time } if @weekly_plan.nil?

    render json: { weekly_plan: weekly_plan_json(@weekly_plan), eod_time: eod_time }
  end

  # Which renewal activities this week is committed to. An unplanned week is committed to none --
  # the same reasoning as `show`: an empty answer, not an error, and looking creates nothing.
  def sharpen_the_saw
    render json: { activity_ids: committed_activity_ids }
  end

  # Replaces the week's committed set. The activity library itself is standing and belongs to the
  # user; this is only the statement "these are the ones I am renewing with this week".
  def update_sharpen_the_saw
    submitted = Array(params[:activity_ids]).map(&:to_i).uniq
    owned = current_user.sharpen_the_saw_activities.active.pluck(:sharpen_the_saw_activity_id)

    unless (submitted - owned).empty?
      return render json: { errors: [ "Invalid sharpen the saw activity selected" ] },
                    status: :unprocessable_entity
    end

    # An activity a task is already scheduled against stays committed even when the client leaves
    # it out. Having put it in the calendar is the stronger statement of the two, and dropping the
    # join row would leave the week contradicting its own schedule.
    final = submitted | scheduled_activity_ids

    ActiveRecord::Base.transaction do
      @weekly_plan.weekly_plan_sts_activities.where.not(sharpen_the_saw_activity_id: final).destroy_all
      final.each do |activity_id|
        WeeklyPlanStsActivity.find_or_create_by!(
          weekly_plan_id: @weekly_plan.weekly_plan_id,
          sharpen_the_saw_activity_id: activity_id
        )
      end
    end

    render json: { activity_ids: committed_activity_ids }
  end

  private

  def committed_activity_ids
    return [] if @weekly_plan.nil?

    @weekly_plan.weekly_plan_sts_activities.pluck(:sharpen_the_saw_activity_id).sort
  end

  def scheduled_activity_ids
    @weekly_plan.tasks.where.not(sharpen_the_saw_activity_id: nil)
                .distinct.pluck(:sharpen_the_saw_activity_id)
  end

  def weekly_plan_json(plan)
    tasks = plan.tasks
                .includes(:sharpen_the_saw_activity, goal: :role)
                .order(:day_of_week, :start_time)

    {
      weekly_plan_id: plan.weekly_plan_id,
      start_date: plan.start_date.iso8601,
      end_date: plan.end_date.iso8601,
      tasks: tasks.map { |t| task_json(t) },
      check_ins: plan.check_ins.order(:day_of_week).map { |c| check_in_json(c) }
    }
  end

  # The whole week's check-ins rather than today's, because the server does not know which day is
  # today -- it stores no timezone for the user, so the client picks its own column out of these
  # exactly as it does with tasks.
  def check_in_json(check_in)
    { day_of_week: check_in.day_of_week, status: check_in.status }
  end

  def eod_time
    current_user.eod_time.strftime("%H:%M")
  end

  # The link fields are returned as separate parts rather than one sentence: the display names for
  # the four Sharpen the Saw dimensions live in the frontend, so it composes the final label.
  def task_json(task)
    {
      task_id: task.task_id,
      title: task.task_name,
      day_of_week: task.day_of_week,
      start_time: task.start_time.strftime("%H:%M"),
      end_time: task.end_time.strftime("%H:%M"),
      is_fixed_appointment: task.is_fixed_appointment,
      is_daily_priority: task.is_daily_priority,
      # The goal's flag, not the task's -- a weekly priority is a property of what the task serves.
      # It rides along here because the dashboard reads a week without ever fetching its goals, and
      # the calendar reserves one colour for it.
      is_weekly_priority: task.goal&.is_weekly_priority || false,
      is_completed: task.is_completed,
      link_kind: link_kind(task),
      link_text: task.goal&.description || task.sharpen_the_saw_activity&.activity_description,
      role_name: task.goal&.role&.role_name,
      # The role's colour, for the same reason `is_weekly_priority` rides along: the dashboard draws
      # a week without ever fetching its goals, and it tints a task by the role behind it.
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
