class CheckInsController < ApplicationController
  include Authenticatable
  include WeekScoped

  # A check-in belongs to a plan, so looking must not create one -- the same rule the reflections
  # endpoints follow. Reading is done through the dashboard's own weekly-plan response rather than
  # here: the client needs the plan before it can decide whether to prompt at all.
  before_action :find_weekly_plan

  # Records that tonight's check-in was dealt with, and how. Upserted rather than created because a
  # night dismissed at nine and saved at eleven is one night, not two.
  #
  # There is no "has this week closed?" guard, unlike the reflection this usually accompanies. That
  # one exists because /evening-reflections can navigate into a past week; the check-in is only ever
  # about today, on the week the dashboard is standing in.
  def upsert
    if @weekly_plan.nil?
      return render json: { errors: [ "Plan this week before checking in to it" ] },
                    status: :unprocessable_entity
    end

    check_in = @weekly_plan.check_ins.find_or_initialize_by(day_of_week: params[:day_of_week])

    # A night already saved is not un-saved by a later dismissal. The prompt is suppressed as soon
    # as a check-in exists, so only a stale client can ask for this, and losing the record of a
    # completed night to one would be the worse of the two outcomes.
    return render json: { check_in: check_in_json(check_in) } if
      check_in.completed? && params[:status] == CheckIn::SKIPPED

    check_in.update!(status: params[:status])

    render json: { check_in: check_in_json(check_in) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def check_in_json(check_in)
    { day_of_week: check_in.day_of_week, status: check_in.status }
  end
end
