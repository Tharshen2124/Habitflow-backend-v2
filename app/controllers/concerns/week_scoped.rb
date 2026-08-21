# Resolves the weekly plan a request applies to.
#
# `week_start` is always supplied by the client and is always a Monday. The server deliberately
# never derives "the current week" itself: it stores no timezone for the user, so at UTC+8 the
# first eight hours of local Monday are still Sunday in UTC and it would answer for the wrong week.
module WeekScoped
  extend ActiveSupport::Concern

  private

  # Writes: the plan is created the first time a week is used.
  def set_weekly_plan
    return render_invalid_week_start if week_start.nil?

    @weekly_plan = WeeklyPlan.for!(current_user, week_start)
  end

  # Reads: @weekly_plan is nil when the user has not planned that week. Merely looking at a week
  # must not bring it into existence, or every dashboard visit would plan the week for the user.
  def find_weekly_plan
    return render_invalid_week_start if week_start.nil?

    @weekly_plan = current_user.weekly_plans.find_by(start_date: week_start)
  end

  # The requested Monday itself. Exposed separately because an action behind `find_weekly_plan`
  # still has to reason about the week even when no plan exists for it -- carry-forward has to know
  # which week to look back from before there is anything to look back into.
  def week_start
    return @week_start if defined?(@week_start)

    @week_start = parse_week_start
  end

  def parse_week_start
    date = Date.iso8601(params[:week_start].to_s)
    date.monday? ? date : nil
  rescue Date::Error
    nil
  end

  def render_invalid_week_start
    render json: { errors: [ "week_start must be an ISO 8601 date falling on a Monday" ] },
           status: :unprocessable_entity
  end
end
