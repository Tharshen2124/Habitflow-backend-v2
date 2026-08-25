class RolesController < ApplicationController
  include Authenticatable
  include WeekScoped
  include CalendarSyncable

  before_action :set_role, only: [ :update_role, :destroy_role, :archive_preview ]
  before_action :set_archived_role, only: [ :restore_role ]
  # Every action reports a role together with the goals it holds in one particular week, so they
  # all need the week resolved first. The two pure reads resolve it without creating it: opening
  # the roles page must not file a plan for a week the user has not planned, or the dashboard would
  # stop offering to plan it.
  before_action :find_weekly_plan, only: [ :index, :archive_preview ]
  before_action :set_weekly_plan, except: [ :index, :archive_preview ]

  def index
    roles = current_user.roles.active.preload(:goals)

    render json: {
      roles: roles.map { |r| role_json(r) },
      archived_roles: current_user.roles.archived.map { |r| archived_role_json(r) }
    }
  end

  # Onboarding step 1. Submitting it again reconciles against what is already there rather than
  # rebuilding from scratch: a plain destroy_all would take every past week's goals with it, and
  # would fail outright once tasks point at the goals being removed.
  def create
    submitted_roles = params.permit(
      roles: [ :role_id, :name, :icon_id, :color_id, goals: [ :goal_id, :text, :is_weekly_priority ] ]
    )[:roles] || []

    reconciled = ActiveRecord::Base.transaction { reconcile_roles(submitted_roles) }

    sync_calendar_later
    render json: { roles: reconciled.map { |r| role_json(r.reload) } }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  # Standing-page single-record create.
  def create_role
    role = current_user.roles.create!(role_params)
    render json: { role: role_json(role) }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update_role
    @role.update!(role_params)
    # A role's name and colour reach the description and the colour of every event of every task
    # under it -- in this week and in next week's plan if one exists.
    sync_calendar_later
    render json: { role: role_json(@role) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  # What archiving this role would cost, so the confirmation dialog can state real numbers instead
  # of a vague warning.
  def archive_preview
    render json: { preview: ArchiveRole.preview(@role, @weekly_plan) }
  end

  def destroy_role
    archived = ArchiveRole.call(@role, @weekly_plan)
    # ArchiveRole takes this week's unfinished tasks off the calendar, so their events go too.
    sync_calendar_later
    render json: { archived: archived }
  end

  def restore_role
    ArchiveRole.restore(@role)
    render json: { role: role_json(@role) }
  end

  private

  def reconcile_roles(submitted_roles)
    kept = submitted_roles.map do |role_params|
      role = find_submitted_role(role_params) || current_user.roles.new
      role.update!(
        role_name: role_params[:name],
        icon_id: role_params[:icon_id],
        color_id: role_params[:color_id]
      )
      reconcile_goals(role, role_params[:goals] || [])
      role
    end

    (current_user.roles.active.to_a - kept).each { |role| ArchiveRole.call(role, @weekly_plan) }
    kept
  end

  # Onboarding creates roles client-side, so the first submit carries no ids and has to match on
  # name; later submits round-trip the id the server assigned.
  def find_submitted_role(role_params)
    active = current_user.roles.active
    return active.find_by(role_id: role_params[:role_id]) if role_params[:role_id].present?

    active.find_by("lower(role_name) = ?", role_params[:name].to_s.downcase)
  end

  def reconcile_goals(role, submitted_goals)
    existing = role.goals.active.where(weekly_plan_id: @weekly_plan.weekly_plan_id).to_a

    kept = submitted_goals.map do |goal_params|
      goal = find_submitted_goal(existing, goal_params) ||
             role.goals.new(weekly_plan_id: @weekly_plan.weekly_plan_id)
      goal.update!(
        description: goal_params[:text],
        is_weekly_priority: goal_params[:is_weekly_priority] || false
      )
      goal
    end

    (existing - kept).each { |goal| ArchiveGoal.call(goal) }
  end

  def find_submitted_goal(existing, goal_params)
    if goal_params[:goal_id].present?
      return existing.find { |g| g.goal_id.to_s == goal_params[:goal_id].to_s }
    end

    existing.find { |g| g.description.casecmp?(goal_params[:text].to_s) }
  end

  # Scoped to the current user AND active, so another user's id and an already-archived one both
  # read as "not found" rather than leaking existence through a 403.
  def set_role
    @role = current_user.roles.active.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Role not found" }, status: :not_found
  end

  def set_archived_role
    @role = current_user.roles.archived.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Role not found" }, status: :not_found
  end

  def role_params
    params.permit(:role_name, :icon_id, :color_id)
  end

  # Roles are standing; goals belong to exactly one week. A role carried into a new week starts it
  # with an empty goals array.
  def role_json(role)
    goals = role.goals.select do |g|
      g.weekly_plan_id == @weekly_plan&.weekly_plan_id && g.deleted_at.nil?
    end

    {
      role_id: role.role_id,
      name: role.role_name,
      icon_id: role.icon_id,
      color_id: role.color_id,
      goals: goals.map { |g| goal_json(g) }
    }
  end

  def archived_role_json(role)
    {
      role_id: role.role_id,
      name: role.role_name,
      icon_id: role.icon_id,
      color_id: role.color_id,
      deleted_at: role.deleted_at
    }
  end

  def goal_json(goal)
    {
      goal_id: goal.goal_id,
      text: goal.description,
      is_weekly_priority: goal.is_weekly_priority,
      is_completed: goal.is_completed
    }
  end
end
