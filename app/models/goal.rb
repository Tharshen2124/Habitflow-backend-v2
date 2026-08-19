class Goal < ApplicationRecord
  self.primary_key = "goal_id"

  belongs_to :role, foreign_key: "role_id", primary_key: "role_id"
  belongs_to :weekly_plan, foreign_key: "weekly_plan_id", primary_key: "weekly_plan_id"

  has_many :tasks, foreign_key: "goal_id", primary_key: "goal_id"

  validates :description, presence: true
end
