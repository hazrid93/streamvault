# frozen_string_literal: true

class List < ApplicationRecord
  belongs_to :user
  has_many :list_items, dependent: :destroy

  validates :name, presence: true, length: { maximum: 100 }
  validates :name, uniqueness: { scope: :user_id, case_sensitive: false }
end