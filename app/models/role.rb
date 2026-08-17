class Role < ApplicationRecord
  self.primary_key = "role_id"

  belongs_to :user, foreign_key: "user_id", primary_key: "user_id"
  has_many :goals, foreign_key: "role_id", dependent: :destroy

  validates :role_name, presence: true
end
