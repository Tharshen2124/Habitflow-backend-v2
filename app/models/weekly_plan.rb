class WeeklyPlan < ApplicationRecord
  self.primary_key = "weekly_plan_id"

  belongs_to :user, foreign_key: "user_id", primary_key: "user_id"

  # Tasks are declared before goals: destroy order follows declaration order and a task holds a
  # foreign key to a goal.
  has_many :tasks, foreign_key: "weekly_plan_id", primary_key: "weekly_plan_id", dependent: :destroy
  has_many :goals, foreign_key: "weekly_plan_id", primary_key: "weekly_plan_id", dependent: :destroy
  has_many :weekly_plan_sts_activities, foreign_key: "weekly_plan_id",
           primary_key: "weekly_plan_id", dependent: :destroy
  has_many :sharpen_the_saw_activities, through: :weekly_plan_sts_activities

  before_validation :derive_end_date

  validates :start_date, presence: true
  validate :start_date_is_a_monday

  # The single resolver every week-scoped write goes through. Idempotent, so all four onboarding
  # steps land in the same plan. `start_date` is always client-supplied — the server never derives
  # "the current week" itself, because it stores no timezone for the user.
  def self.for!(user, start_date)
    find_or_create_by!(user_id: user.user_id, start_date: start_date)
  end

  private

  def derive_end_date
    self.end_date = start_date + 6 if start_date.present?
  end

  def start_date_is_a_monday
    return if start_date.blank?

    errors.add(:start_date, "must be a Monday") unless start_date.monday?
  end
end
