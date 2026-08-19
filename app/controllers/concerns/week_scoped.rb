# Resolves the weekly plan a request applies to.
#
# `week_start` is always supplied by the client and is always a Monday. The server deliberately
# never derives "the current week" itself: it stores no timezone for the user, so at UTC+8 the
# first eight hours of local Monday are still Sunday in UTC and it would answer for the wrong week.
module WeekScoped
  extend ActiveSupport::Concern

  private

  def set_weekly_plan
    start_date = Date.iso8601(params[:week_start].to_s)
    return render_invalid_week_start unless start_date.monday?

    @weekly_plan = WeeklyPlan.for!(current_user, start_date)
  rescue Date::Error
    render_invalid_week_start
  end

  def render_invalid_week_start
    render json: { errors: [ "week_start must be an ISO 8601 date falling on a Monday" ] },
           status: :unprocessable_entity
  end
end
