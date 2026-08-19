class Role < ApplicationRecord
  self.primary_key = "role_id"

  belongs_to :user, foreign_key: "user_id", primary_key: "user_id"

  # Deliberately no `dependent:`. A role's goals belong to the weeks they were planned in, and
  # every past week's per-role stats resolve through goal -> role. Destroying them with the role
  # would erase that history, so a role is archived (see ArchiveRole) and its rows stay put.
  has_many :goals, foreign_key: "role_id", primary_key: "role_id"

  validates :role_name, presence: true

  scope :active, -> { where(deleted_at: nil) }
  scope :archived, -> { where.not(deleted_at: nil) }

  def archived?
    deleted_at.present?
  end
end
