class SharpenTheSawActivity < ApplicationRecord
  self.primary_key = "sharpen_the_saw_activity_id"
  belongs_to :user, foreign_key: "user_id", primary_key: "user_id"

  # The onboarding bulk create hard-deletes activities, so the join rows have to go with them or
  # the new foreign key raises on re-submit.
  has_many :weekly_plan_sts_activities, foreign_key: "sharpen_the_saw_activity_id",
           primary_key: "sharpen_the_saw_activity_id", dependent: :destroy

  validates :dimension, presence: true
  validates :activity_description, presence: true

  scope :active, -> { where(is_deleted: false) }
end
