class SharpenTheSawActivity < ApplicationRecord
  self.primary_key = "sharpen_the_saw_activity_id"
  belongs_to :user, foreign_key: "user_id", primary_key: "user_id"
  validates :dimension, presence: true
  validates :activity_description, presence: true

  scope :active, -> { where(is_deleted: false) }
end
