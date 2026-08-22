# Resolves the weekly plan a request applies to.
#
# `week_start` is always supplied by the client and is always a Monday. The server deliberately
# never derives "the current week" itself: it stores no timezone for the user, so at UTC+8 the
# first eight hours of local Monday are still Sunday in UTC and it would answer for the wrong week.
module WeekScoped
  extend ActiveSupport::Concern

  # The furthest a range endpoint will look. Shared rather than per-controller: /history, the
  # reflections week strip and /analytics all read a `from`/`to` pair, and three copies of the
  # same cap would be three places to get it wrong.
  MAX_RANGE_DAYS = 52 * 7

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
    parse_monday(params[:week_start])
  end

  # Extracted from parse_week_start because the reflections week strip parses a `from`/`to` pair
  # with exactly the same rule, and a second copy of it would be a second place to get wrong.
  def parse_monday(value)
    date = Date.iso8601(value.to_s)
    date.monday? ? date : nil
  rescue Date::Error
    nil
  end

  # The `from`/`to` pair the range endpoints take, or nil once it has rendered the refusal itself.
  # A caller reads it as:
  #
  #   range = parse_week_range
  #   return if range.nil?
  #   from, to = range
  def parse_week_range
    from = parse_monday(params[:from])
    to = parse_monday(params[:to])

    if from.nil? || to.nil?
      render_invalid_week_start
      return nil
    end

    if to < from || (to - from).to_i > MAX_RANGE_DAYS
      render json: { errors: [ "Range must run forwards and cover 52 weeks or fewer" ] },
             status: :unprocessable_entity
      return nil
    end

    [ from, to ]
  end

  def render_invalid_week_start
    render json: { errors: [ "week_start must be an ISO 8601 date falling on a Monday" ] },
           status: :unprocessable_entity
  end
end
