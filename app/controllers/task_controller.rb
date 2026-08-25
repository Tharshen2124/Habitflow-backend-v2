class TaskController < ApplicationController
  include Authenticatable
  include WeekScoped
  include CalendarSyncable

  # `update_completion` is the one action that is not week-scoped: a task names its own week through
  # `weekly_plan_id`, and demanding a `week_start` alongside the id would be asking the client to
  # restate something the row already knows -- and to be wrong about it if the two ever disagreed.
  before_action :set_weekly_plan, except: [ :update_completion ]

  def index_fixed_appointments
    render json: { appointments: plan_tasks(fixed: true).map { |t| appointment_json(t) } }
  end

  def create_fixed_appointments
    submitted = params.permit(appointments: [ :task_id, :title, :description, :day_of_week, :start_time, :end_time ])[:appointments] || []

    return render_unknown_task_id if unknown_task_ids(submitted, fixed: true).any?

    ActiveRecord::Base.transaction do
      reconcile_tasks(submitted, fixed: true) do |attrs|
        {
          task_name: attrs[:title],
          description: attrs[:description],
          day_of_week: attrs[:day_of_week],
          start_time: attrs[:start_time],
          end_time: attrs[:end_time]
        }
      end
    end

    sync_calendar_later
    render json: { appointments: plan_tasks(fixed: true).map { |t| appointment_json(t) } }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def index_scheduled_tasks
    render json: { tasks: plan_tasks(fixed: false).map { |t| task_json(t) } }
  end

  def create_scheduled_tasks
    submitted = params.permit(tasks: [ :task_id, :title, :day_of_week, :start_time, :end_time, :goal_id, :sharpen_the_saw_activity_id, :is_daily_priority ])[:tasks] || []

    return render_unknown_task_id if unknown_task_ids(submitted, fixed: false).any?

    # Goals are scoped to the plan, not just to the user: a task may only serve a goal from its own
    # week. Activities are a standing library, so user-level ownership is the right check there.
    owned_goal_ids = @weekly_plan.goals.pluck(:goal_id)
    owned_activity_ids = current_user.sharpen_the_saw_activities.pluck(:sharpen_the_saw_activity_id)

    invalid_link = submitted.any? do |t|
      (t[:goal_id].present? && !owned_goal_ids.include?(t[:goal_id].to_i)) ||
        (t[:sharpen_the_saw_activity_id].present? && !owned_activity_ids.include?(t[:sharpen_the_saw_activity_id].to_i))
    end

    if invalid_link
      return render json: { errors: [ "Invalid goal or sharpen the saw activity selected" ] }, status: :unprocessable_entity
    end

    ActiveRecord::Base.transaction do
      reconciled = reconcile_tasks(submitted, fixed: false) do |attrs|
        {
          task_name: attrs[:title],
          day_of_week: attrs[:day_of_week],
          start_time: attrs[:start_time],
          end_time: attrs[:end_time],
          goal_id: attrs[:goal_id].presence,
          sharpen_the_saw_activity_id: attrs[:sharpen_the_saw_activity_id].presence,
          is_daily_priority: attrs[:is_daily_priority] || false
        }
      end

      commit_activities_to_plan(reconciled)
    end

    sync_calendar_later
    render json: { tasks: plan_tasks(fixed: false).map { |t| task_json(t) } }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  # Ticking a task off, which until now nothing could do: `is_completed` was read into four JSON
  # shapes and written by none of them, so every row sat at the column default and /history had
  # nothing to report. Deliberately its own endpoint rather than a field on the bulk creates --
  # those reconcile a whole week's plan, and marking one task done is not a replanning of the week.
  #
  # Fixed appointments are tickable too. `fixed_appointment_has_no_priority_or_links` forbids them a
  # goal, an activity and a priority, but says nothing about completion, and the End-of-Day
  # checklist lists a 6am gym session next to everything else the day held.
  def update_completion
    task = current_user.tasks.find_by(task_id: params[:id])
    return render json: { errors: [ "Task not found" ] }, status: :not_found if task.nil?

    task.update!(is_completed: ActiveModel::Type::Boolean.new.cast(params[:is_completed]))

    render json: { task: { task_id: task.task_id, is_completed: task.is_completed } }
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def plan_tasks(fixed:)
    @weekly_plan.tasks.where(is_fixed_appointment: fixed).order(:day_of_week, :start_time)
  end

  # Reconciles this week's tasks against what was submitted, rather than rebuilding them.
  #
  # Rebuilding handed every task a new id and reset `is_completed`, because the client has no reason
  # to send a column it never edits. /history and /analytics resolve a week through
  # task -> goal -> role, so one mid-week edit erased everything the user had already ticked off.
  #
  # A submitted id is updated in place and keeps both its id and its completion. A row the client
  # no longer sends is one the user deleted -- and only the unfinished ones go, which is the rule
  # ArchiveGoal already applies to a dropped goal's tasks: a completed task is a fact about that
  # week, and letting it be deleted would let a user raise their own completion rate.
  #
  # Onboarding sends no ids at all, so for it every task is a create and there is nothing to delete.
  def reconcile_tasks(submitted, fixed:)
    existing = plan_tasks(fixed: fixed).index_by { |t| t.task_id.to_s }

    kept = submitted.map do |attrs|
      task = existing[attrs[:task_id].to_s]
      next task.tap { |t| t.update!(yield(attrs)) } if task

      current_user.tasks.create!(
        yield(attrs).merge(is_fixed_appointment: fixed, weekly_plan: @weekly_plan)
      )
    end

    (existing.values - kept).reject(&:is_completed).each(&:destroy!)
    kept
  end

  # A submitted id that is not one of this week's tasks of that kind is a broken client, not a
  # deletion. Failing loudly beats silently creating a duplicate under a fresh id.
  def unknown_task_ids(submitted, fixed:)
    submitted.filter_map { |t| t[:task_id].presence&.to_s } -
      plan_tasks(fixed: fixed).pluck(:task_id).map(&:to_s)
  end

  def render_unknown_task_id
    render json: { errors: [ "Unknown task id" ] }, status: :unprocessable_entity
  end

  # An activity scheduled into a week is committed to that week, even if it was added from the
  # standing Sharpen the Saw page after the week's activities were first chosen.
  def commit_activities_to_plan(tasks)
    tasks.filter_map(&:sharpen_the_saw_activity_id).uniq.each do |activity_id|
      WeeklyPlanStsActivity.find_or_create_by!(
        weekly_plan_id: @weekly_plan.weekly_plan_id,
        sharpen_the_saw_activity_id: activity_id
      )
    end
  end

  def appointment_json(task)
    {
      task_id: task.task_id,
      title: task.task_name,
      description: task.description,
      day_of_week: task.day_of_week,
      start_time: task.start_time.strftime("%H:%M"),
      end_time: task.end_time.strftime("%H:%M"),
      is_completed: task.is_completed
    }
  end

  def task_json(task)
    {
      task_id: task.task_id,
      title: task.task_name,
      day_of_week: task.day_of_week,
      start_time: task.start_time.strftime("%H:%M"),
      end_time: task.end_time.strftime("%H:%M"),
      goal_id: task.goal_id,
      sharpen_the_saw_activity_id: task.sharpen_the_saw_activity_id,
      is_daily_priority: task.is_daily_priority,
      is_completed: task.is_completed
    }
  end
end
