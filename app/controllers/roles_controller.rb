class RolesController < ApplicationController
  include Authenticatable

  def index
    render json: { roles: current_user.roles.includes(:goals).map { |r| role_json(r) } }
  end

  def create
    submitted_roles = params.permit(roles: [ :name, :icon_id, goals: [ :text, :is_weekly_priority ] ])[:roles] || []

    created = ActiveRecord::Base.transaction do
      current_user.roles.destroy_all

      submitted_roles.map do |role_params|
        role = current_user.roles.create!(
          role_name: role_params[:name],
          icon_id: role_params[:icon_id]
        )

        (role_params[:goals] || []).each do |goal_params|
          role.goals.create!(
            description: goal_params[:text],
            is_weekly_priority: goal_params[:is_weekly_priority] || false
          )
        end

        role
      end
    end

    render json: { roles: created.map { |r| role_json(r) } }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def role_json(role)
    {
      role_id: role.role_id,
      name: role.role_name,
      icon_id: role.icon_id,
      goals: role.goals.map { |g| { goal_id: g.goal_id, text: g.description, is_weekly_priority: g.is_weekly_priority } }
    }
  end
end
