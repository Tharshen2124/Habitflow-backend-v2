class SharpenTheSawActivityController < ApplicationController
  include Authenticatable

  def index
    render json: { activities: current_user.sharpen_the_saw_activities.map { |a| activity_json(a) } }
  end

  def create
    submitted_activities = params.permit(activities: [ :dimension, :activity_description ])[:activities] || []

    created = ActiveRecord::Base.transaction do
      current_user.sharpen_the_saw_activities.destroy_all

      submitted_activities.map do |activity_params|
        current_user.sharpen_the_saw_activities.create!(
          dimension: activity_params[:dimension],
          activity_description: activity_params[:activity_description]
        )
      end
    end

    render json: { activities: created.map { |a| activity_json(a) } }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def activity_json(activity)
    {
      sharpen_the_saw_activity_id: activity.sharpen_the_saw_activity_id,
      dimension: activity.dimension,
      activity_description: activity.activity_description
    }
  end
end
