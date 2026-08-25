class SharpenTheSawActivity < ApplicationRecord
  self.primary_key = "sharpen_the_saw_activity_id"

  # The display names for the four dimensions. `dimension` is a free string holding the id
  # ("social"), and until now the label ("Social / Emotional") existed only in the frontend --
  # WeeklyPlansController sends the raw id on purpose and lets next-app compose the label.
  #
  # A Google Calendar event is written server-side and has no frontend to ask, so the labels have to
  # exist here too. The copy in next-app/lib/sharpen-the-saw-dimensions.ts remains the one the UI
  # renders from; this one is for text that leaves the app. Keep them in step.
  DIMENSION_LABELS = {
    "physical" => "Physical",
    "spiritual" => "Spiritual",
    "mental" => "Mental",
    "social" => "Social / Emotional"
  }.freeze

  def dimension_label = DIMENSION_LABELS.fetch(dimension, dimension)
  belongs_to :user, foreign_key: "user_id", primary_key: "user_id"

  # The onboarding bulk create hard-deletes activities, so the join rows have to go with them or
  # the new foreign key raises on re-submit.
  has_many :weekly_plan_sts_activities, foreign_key: "sharpen_the_saw_activity_id",
           primary_key: "sharpen_the_saw_activity_id", dependent: :destroy

  validates :dimension, presence: true
  validates :activity_description, presence: true

  scope :active, -> { where(deleted_at: nil) }
end
