class EveningReflectionsController < ApplicationController
  include Authenticatable
  include WeekScoped

  # Reads only. A reflection hangs off a weekly plan, so writing one must not be what brings that
  # plan into existence: a plan row existing is the client's only answer to "is this week planned?",
  # and filing one here would make the dashboard's Create Weekly Plan card vanish for a week the
  # user never planned. Reflecting on a week you did not plan is refused, not quietly accommodated.
  before_action :find_weekly_plan, only: [ :index, :upsert ]


  # One week in full: its reflections and its summary, in a single round trip. An unplanned week is
  # a normal answer, as it is for weekly_plans#show.
  def index
    return render json: { planned: false, reflections: [], summary: nil } if @weekly_plan.nil?

    render json: {
      planned: true,
      reflections: @weekly_plan.evening_reflections.order(:day_of_week).map { |r| reflection_json(r) },
      summary: @weekly_plan.weekly_summary && summary_json(@weekly_plan.weekly_summary)
    }
  end

  # Create and edit are one path. The client knows which day it is writing, not whether a row for
  # that day already exists, and the unique index means asking is the same question as writing.
  def upsert
    if @weekly_plan.nil?
      return render json: { errors: [ "Plan this week before writing a reflection for it" ] },
                    status: :unprocessable_entity
    end

    if week_has_closed?
      return render json: { errors: [ "This week has ended and can no longer be edited" ] },
                    status: :unprocessable_entity
    end

    reflection = @weekly_plan.evening_reflections.find_or_initialize_by(day_of_week: params[:day_of_week])
    reflection.update!(content: params[:content])

    render json: { reflection: reflection_json(reflection) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  # The sidebar's week strip: how many days each week has written and whether it has been
  # summarised, never the reflection text itself. Deliberately not week-scoped -- it reasons about a
  # range, and looking creates nothing.
  def weeks
    range = parse_week_range
    return if range.nil?

    from, to = range

    render json: { weeks: week_summaries(from, to) }
  end

  private

  # The one thing the server can say about "has this week passed" without knowing the user's
  # timezone. Pastness is a client fact -- the UI is what actually stops a closed week being
  # edited -- so this is a backstop against a hand-written request, and the day of slack is there
  # so it can never fire for someone whose local Sunday is the server's Monday.
  def week_has_closed?
    @weekly_plan.end_date < Date.current - 1
  end

  def week_summaries(from, to)
    plans = current_user.weekly_plans.where(start_date: from..to).order(start_date: :desc)
    plan_ids = plans.map(&:weekly_plan_id)

    counts = EveningReflection.where(weekly_plan_id: plan_ids).group(:weekly_plan_id).count
    summarised = WeeklySummary.where(weekly_plan_id: plan_ids).pluck(:weekly_plan_id).to_set

    plans.map do |plan|
      {
        week_start: plan.start_date.iso8601,
        reflection_count: counts.fetch(plan.weekly_plan_id, 0),
        has_summary: summarised.include?(plan.weekly_plan_id)
      }
    end
  end

  def reflection_json(reflection)
    {
      day_of_week: reflection.day_of_week,
      content: reflection.content,
      updated_at: reflection.updated_at.iso8601
    }
  end

  def summary_json(summary)
    {
      content: summary.content,
      model: summary.model,
      generated_at: summary.generated_at.iso8601
    }
  end
end
