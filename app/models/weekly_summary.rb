# The AI-written synthesis of a week's seven evening reflections (business rule 10).
#
# Written exactly once per week and never regenerated, which is why the row carries generated_at
# and the model that produced it but no updated_at. The uniqueness validation states the rule; the
# unique index behind it is what holds when two clicks arrive together.
class WeeklySummary < ApplicationRecord
  self.primary_key = "weekly_summary_id"

  belongs_to :weekly_plan, foreign_key: "weekly_plan_id", primary_key: "weekly_plan_id"

  validates :content, presence: true
  validates :model, presence: true
  validates :weekly_plan_id, uniqueness: true
end
