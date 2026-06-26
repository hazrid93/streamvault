# frozen_string_literal: true

class Recommendation < ApplicationRecord
  belongs_to :user

  validates :tmdb_id, presence: true
  validates :imdb_id, presence: true

  scope :ordered, -> { order(:position) }
end
