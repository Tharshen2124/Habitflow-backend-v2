# One night's End-of-Day check-in: the record that the user was asked, and what they did about it.
#
# Until this table existed that answer lived in the browser as localStorage["eod_shown_date"], which
# made "have I already checked in tonight?" a per-device fact -- checking in on a laptop left the
# phone still asking, and clearing site data asked again the same evening.
#
# A `completed` row is deliberately redundant with the evening_reflections row the same save writes:
# the reflection is what gates the check-in's Save button, so one cannot exist without the other.
# What only this table can say is that the user was asked and said not tonight.
class CheckIn < ApplicationRecord
  self.primary_key = "check_in_id"

  COMPLETED = "completed".freeze
  SKIPPED = "skipped".freeze
  STATUSES = [ COMPLETED, SKIPPED ].freeze

  belongs_to :weekly_plan, foreign_key: "weekly_plan_id", primary_key: "weekly_plan_id"

  validates :day_of_week, presence: true, inclusion: { in: 0..6 },
            uniqueness: { scope: :weekly_plan_id }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :completed, -> { where(status: COMPLETED) }
  scope :skipped, -> { where(status: SKIPPED) }

  def completed?
    status == COMPLETED
  end

  def skipped?
    status == SKIPPED
  end

  # The date this check-in was for, derived rather than stored: weekly_plans.start_date is the only
  # place a week's dates live.
  def date
    weekly_plan.start_date + day_of_week
  end
end
