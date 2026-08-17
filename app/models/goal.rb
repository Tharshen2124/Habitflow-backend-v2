class Goal < ApplicationRecord
  self.primary_key = "goal_id"

  belongs_to :role, foreign_key: "role_id", primary_key: "role_id"

  validates :description, presence: true
end
