class SharpenTheSawActivityController < ApplicationController
  include Authenticatable
  include WeekScoped

  before_action :set_activity, only: [ :update_activity, :destroy_activity ]
  # Only the onboarding bulk create is week-scoped. `index` backs both /onboarding/sharpen-the-saw
  # and the standing /sharpen-the-saw-activities page, and the activity library itself belongs to
  # the user rather than to any one week.
  before_action :set_weekly_plan, only: [ :create ]

  def index
    render json: { activities: current_user.sharpen_the_saw_activities.active.map { |a| activity_json(a) } }
  end

  def create
    submitted_activities = params.permit(activities: [ :dimension, :activity_description ])[:activities] || []

    created = ActiveRecord::Base.transaction do
      current_user.sharpen_the_saw_activities.destroy_all

      activities = submitted_activities.map do |activity_params|
        current_user.sharpen_the_saw_activities.create!(
          dimension: activity_params[:dimension],
          activity_description: activity_params[:activity_description]
        )
      end

      commit_activities_to_plan(activities)
      activities
    end

    render json: { activities: created.map { |a| activity_json(a) } }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  # Standing-page single-record create.
  def create_activity
    activity = current_user.sharpen_the_saw_activities.create!(activity_params)
    render json: { activity: activity_json(activity) }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  # Standing-page single-record update (inline rename).
  def update_activity
    @activity.update!(activity_params)
    render json: { activity: activity_json(@activity) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  # Standing-page soft-delete. The row stays so tasks.sharpen_the_saw_activity_id references stay valid.
  def destroy_activity
    @activity.update!(deleted_at: Time.current)
    head :no_content
  end

  private

  # Onboarding has no separate "pick this week's activities" step, so everything defined here is
  # committed to the week it was defined in.
  def commit_activities_to_plan(activities)
    activities.each do |activity|
      WeeklyPlanStsActivity.find_or_create_by!(
        weekly_plan_id: @weekly_plan.weekly_plan_id,
        sharpen_the_saw_activity_id: activity.sharpen_the_saw_activity_id
      )
    end
  end

  # Scoped to the current user AND active — an already-deleted or another user's id both look
  # like "not found" rather than leaking existence via a 403.
  def set_activity
    @activity = current_user.sharpen_the_saw_activities.active.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Activity not found" }, status: :not_found
  end

  def activity_params
    params.permit(:dimension, :activity_description)
  end

  def activity_json(activity)
    {
      sharpen_the_saw_activity_id: activity.sharpen_the_saw_activity_id,
      dimension: activity.dimension,
      activity_description: activity.activity_description
    }
  end
end
