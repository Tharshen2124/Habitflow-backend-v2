# One evening's written reflection, owned by the week it belongs to.
#
# The day is stored as a Monday-indexed 0..6 rather than a date, matching tasks.day_of_week: the
# weekly plan already names the week, so a date column would be a second source of truth that could
# contradict weekly_plans.start_date.
#
# Unlike roles, goals and renewal activities, a reflection has no deleted_at. Soft delete exists in
# this schema so /history and /analytics can resolve a past week through task -> goal -> role;
# nothing resolves through a reflection. It is a journal entry, edited in place.
class EveningReflection < ApplicationRecord
  self.primary_key = "evening_reflection_id"

  belongs_to :weekly_plan, foreign_key: "weekly_plan_id", primary_key: "weekly_plan_id"

  # The cap is not cosmetic: the weekly summary concatenates all seven entries into a single
  # prompt, and this is the only thing bounding how large that request can get.
  validates :content, presence: true, length: { maximum: 2000 }
  validates :day_of_week, presence: true, inclusion: { in: 0..6 },
            uniqueness: { scope: :weekly_plan_id }
end
