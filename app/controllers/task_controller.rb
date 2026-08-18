class TaskController < ApplicationController
  include Authenticatable

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
end
