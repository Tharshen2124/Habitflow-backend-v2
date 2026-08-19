class TaskController < ApplicationController
  include Authenticatable
  include WeekScoped

  before_action :set_weekly_plan

  def index_fixed_appointments
    render json: { appointments: plan_tasks(fixed: true).map { |t| appointment_json(t) } }
  end

  def create_fixed_appointments
    submitted = params.permit(appointments: [ :title, :description, :day_of_week, :start_time, :end_time ])[:appointments] || []

    created = ActiveRecord::Base.transaction do
      plan_tasks(fixed: true).destroy_all

      submitted.map do |appt_params|
        current_user.tasks.create!(
          task_name: appt_params[:title],
          description: appt_params[:description],
          day_of_week: appt_params[:day_of_week],
          start_time: appt_params[:start_time],
          end_time: appt_params[:end_time],
          is_fixed_appointment: true,
          weekly_plan: @weekly_plan
        )
      end
    end

    render json: { appointments: created.map { |t| appointment_json(t) } }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def index_scheduled_tasks
    render json: { tasks: plan_tasks(fixed: false).map { |t| task_json(t) } }
  end

  def create_scheduled_tasks
    submitted = params.permit(tasks: [ :title, :day_of_week, :start_time, :end_time, :goal_id, :sharpen_the_saw_activity_id, :is_daily_priority ])[:tasks] || []

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

    created = ActiveRecord::Base.transaction do
      plan_tasks(fixed: false).destroy_all

      tasks = submitted.map do |task_params|
        current_user.tasks.create!(
          task_name: task_params[:title],
          day_of_week: task_params[:day_of_week],
          start_time: task_params[:start_time],
          end_time: task_params[:end_time],
          goal_id: task_params[:goal_id].presence,
          sharpen_the_saw_activity_id: task_params[:sharpen_the_saw_activity_id].presence,
          is_daily_priority: task_params[:is_daily_priority] || false,
          is_fixed_appointment: false,
          weekly_plan: @weekly_plan
        )
      end

      commit_activities_to_plan(tasks)
      tasks
    end

    render json: { tasks: created.map { |t| task_json(t) } }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def plan_tasks(fixed:)
    @weekly_plan.tasks.where(is_fixed_appointment: fixed)
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
      end_time: task.end_time.strftime("%H:%M")
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
      is_daily_priority: task.is_daily_priority
    }
  end
end
