class WeeklyPlansController < ApplicationController
  include Authenticatable
  include WeekScoped

  before_action :find_weekly_plan

  # Read-only view of one week, for the dashboard. A null plan is a normal answer, not an error:
  # it is how the client knows the week has not been planned yet.
  def show
    return render json: { weekly_plan: nil } if @weekly_plan.nil?

    render json: { weekly_plan: weekly_plan_json(@weekly_plan) }
  end

  private

  def weekly_plan_json(plan)
    tasks = plan.tasks
                .includes(:sharpen_the_saw_activity, goal: :role)
                .order(:day_of_week, :start_time)

    {
      weekly_plan_id: plan.weekly_plan_id,
      start_date: plan.start_date.iso8601,
      end_date: plan.end_date.iso8601,
      tasks: tasks.map { |t| task_json(t) }
    }
  end

  # The link fields are returned as separate parts rather than one sentence: the display names for
  # the four Sharpen the Saw dimensions live in the frontend, so it composes the final label.
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
      dimension: task.sharpen_the_saw_activity&.dimension
    }
  end

  def link_kind(task)
    return "goal" if task.goal_id.present?
    return "activity" if task.sharpen_the_saw_activity_id.present?

    nil
  end
end
