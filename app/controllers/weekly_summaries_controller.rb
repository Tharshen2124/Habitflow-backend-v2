class WeeklySummariesController < ApplicationController
  include Authenticatable
  include WeekScoped

  # A read, for the same reason EveningReflectionsController's is: summarising a week you never
  # planned should be refused, not silently turned into planning it.
  before_action :find_weekly_plan, only: [ :create ]

  DAYS_IN_WEEK = 7

  # Generates the week's summary, once and only ever once.
  #
  # There is deliberately no guard on the week having passed. Read-only applies to reflections --
  # a week that closed with all seven written is exactly the week most worth summarising, and
  # refusing it would mean a user who filled in Sunday on Monday morning could never have one.
  def create
    if @weekly_plan.nil?
      return render json: { errors: [ "Plan this week before summarising it" ] },
                    status: :unprocessable_entity
    end

    if @weekly_plan.weekly_summary.present?
      return render json: { errors: [ already_summarised ] }, status: :unprocessable_entity
    end

    reflections = @weekly_plan.evening_reflections.order(:day_of_week).to_a
    if reflections.size != DAYS_IN_WEEK
      return render json: { errors: [ "Write all 7 reflections before generating a summary" ] },
                    status: :unprocessable_entity
    end

    result = GeminiSummaryClient.summarise(reflections)
    return render json: { errors: [ upstream_message(result.error) ] }, status: upstream_status(result.error) unless result.ok?

    summary = @weekly_plan.create_weekly_summary!(
      content: result.content, model: GeminiSummaryClient::MODEL, generated_at: Time.current
    )
    render json: { summary: summary_json(summary) }, status: :created
  rescue ActiveRecord::RecordNotUnique
    # Two clicks landing together. The validation states the rule, but the unique index is what
    # makes "once" true when both requests read an empty summary before either writes one.
    render json: { errors: [ already_summarised ] }, status: :unprocessable_entity
  end

  private

  def already_summarised
    "This week has already been summarised"
  end

  # The free tier allows five requests a minute, so being throttled is a routine thing to wait out
  # rather than a fault, and it must not read as one.
  def upstream_message(error)
    case error
    when :rate_limited then "The summary service is busy right now — please try again in a minute."
    else "The summary service is unavailable right now — please try again."
    end
  end

  def upstream_status(error)
    error == :rate_limited ? :too_many_requests : :bad_gateway
  end

  def summary_json(summary)
    {
      content: summary.content,
      model: summary.model,
      generated_at: summary.generated_at.iso8601
    }
  end
end
