class TaskController < ApplicationController
  include Authenticatable

  def index_fixed_appointments
    render json: { appointments: current_user.tasks.where(is_fixed_appointment: true).map { |t| appointment_json(t) } }
  end

  def create_fixed_appointments
    submitted = params.permit(appointments: [ :title, :description, :day_of_week, :start_time, :end_time ])[:appointments] || []

    created = ActiveRecord::Base.transaction do
      current_user.tasks.where(is_fixed_appointment: true).destroy_all

      submitted.map do |appt_params|
        current_user.tasks.create!(
          task_name: appt_params[:title],
          description: appt_params[:description],
          day_of_week: appt_params[:day_of_week],
          start_time: appt_params[:start_time],
          end_time: appt_params[:end_time],
          is_fixed_appointment: true
        )
      end
    end

    render json: { appointments: created.map { |t| appointment_json(t) } }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def index_scheduled_tasks
    render json: { tasks: current_user.tasks.where(is_fixed_appointment: false).map { |t| task_json(t) } }
  end

  def create_scheduled_tasks
    submitted = params.permit(tasks: [ :title, :day_of_week, :start_time, :end_time, :goal_id, :sharpen_the_saw_activity_id, :is_daily_priority ])[:tasks] || []

    owned_goal_ids = current_user.roles.joins(:goals).pluck("goals.goal_id")
    owned_activity_ids = current_user.sharpen_the_saw_activities.pluck(:sharpen_the_saw_activity_id)

    invalid_link = submitted.any? do |t|
      (t[:goal_id].present? && !owned_goal_ids.include?(t[:goal_id].to_i)) ||
        (t[:sharpen_the_saw_activity_id].present? && !owned_activity_ids.include?(t[:sharpen_the_saw_activity_id].to_i))
    end

    if invalid_link
      return render json: { errors: [ "Invalid goal or sharpen the saw activity selected" ] }, status: :unprocessable_entity
    end

    created = ActiveRecord::Base.transaction do
      current_user.tasks.where(is_fixed_appointment: false).destroy_all

      submitted.map do |task_params|
        current_user.tasks.create!(
          task_name: task_params[:title],
          day_of_week: task_params[:day_of_week],
          start_time: task_params[:start_time],
          end_time: task_params[:end_time],
          goal_id: task_params[:goal_id].presence,
          sharpen_the_saw_activity_id: task_params[:sharpen_the_saw_activity_id].presence,
          is_daily_priority: task_params[:is_daily_priority] || false,
          is_fixed_appointment: false
        )
      end
    end

    render json: { tasks: created.map { |t| task_json(t) } }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

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
