class GoalsController < ApplicationController
  include Authenticatable
  include WeekScoped

  # Listing candidates is a pure read, so it resolves the week without creating it -- opening the
  # planning flow must not file a plan for a week the user has not planned yet.
  before_action :find_weekly_plan, only: [ :carry_forward_candidates ]
  before_action :set_weekly_plan, except: [ :carry_forward_candidates ]
  before_action :set_goal, only: [ :update, :destroy ]
  before_action :set_dropped_goal, only: [ :restore ]

  def create
    role = current_user.roles.active.find(params[:role_id])
    goal = role.goals.create!(goal_params.merge(weekly_plan_id: @weekly_plan.weekly_plan_id))

    render json: { goal: goal_json(goal) }, status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Role not found" }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    @goal.update!(goal_params)
    render json: { goal: goal_json(@goal) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def destroy
    render json: { archived: ArchiveGoal.call(@goal) }
  end

  # Backs the undo affordance on the roles page. Restricted to the requested week: reviving a goal
  # dropped weeks ago would silently rewrite that week's outcomes from "dropped" back to "missed".
  def restore
    if @goal.weekly_plan_id != @weekly_plan.weekly_plan_id
      return render json: { errors: [ "Only a goal in the requested week can be restored" ] },
                    status: :unprocessable_entity
    end

    ArchiveGoal.restore(@goal)
    render json: { goal: goal_json(@goal) }
  end

  # Last week's goals, offered as a starting point for this one. Goals belonging to an archived
  # role are left out -- retiring a role should stop it turning up in next week's planning.
  def carry_forward_candidates
    render json: { candidates: previous_week_goals.map { |g| candidate_json(g) } }
  end

  # Each selection becomes a fresh goal in this week plus a link back to the one it continues.
  def carry_forward
    sources = previous_week_goals.where(goal_id: params[:goal_ids] || [])

    created = ActiveRecord::Base.transaction { sources.map { |source| carry(source) } }

    render json: { goals: created.map { |g| goal_json(g) } }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def carry(source)
    destination = source.role.goals.create!(
      weekly_plan_id: @weekly_plan.weekly_plan_id,
      description: source.description,
      is_weekly_priority: source.is_weekly_priority
    )
    GoalCarryover.create!(source_goal: source, destination_goal: destination)
    destination
  end

  # The most recent week the user actually planned, not simply the week before. Someone coming back
  # after a gap has nothing at `week_start - 7`, and offering them an empty list is the same as
  # telling them last term's goals never happened.
  def previous_week_goals
    previous = current_user.weekly_plans
                           .where("start_date < ?", week_start)
                           .order(start_date: :desc)
                           .first
    return Goal.none if previous.nil?

    # A goal can only be carried forward once, so anything already continued is filtered out --
    # the unique index would reject it anyway.
    previous.goals.active
            .joins(:role).where(roles: { deleted_at: nil })
            .where.missing(:carried_to)
            .order(:goal_id)
  end

  def user_goals
    Goal.joins(:weekly_plan).where(weekly_plans: { user_id: current_user.user_id })
  end

  def set_goal
    @goal = user_goals.active.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Goal not found" }, status: :not_found
  end

  def set_dropped_goal
    @goal = user_goals.dropped.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Goal not found" }, status: :not_found
  end

  def goal_params
    params.permit(:description, :is_weekly_priority, :is_completed)
  end

  def goal_json(goal)
    {
      goal_id: goal.goal_id,
      role_id: goal.role_id,
      text: goal.description,
      is_weekly_priority: goal.is_weekly_priority,
      is_completed: goal.is_completed
    }
  end

  def candidate_json(goal)
    goal_json(goal).merge(role_name: goal.role.role_name)
  end
end
