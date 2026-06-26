# frozen_string_literal: true

class Recommendation < ApplicationRecord
  belongs_to :user

  validates :tmdb_id, presence: true
  validates :imdb_id, presence: true

  scope :ordered, -> { order(:position) }

  # Replace all of a user's recommendations in a single transaction.
  # Deletes old rows and inserts new ones with sequential positions.
  def self.replace_recommendations(user, items)
    transaction do
      user.recommendations.delete_all
      items.each_with_index do |item, index|
        user.recommendations.create!(
          tmdb_id: item[:tmdb_id],
          imdb_id: item[:imdb_id],
          title: item[:title],
          poster_url: item[:poster_url],
          content_type: item[:type],
          year: item[:year]&.to_s,
          position: index
        )
      end
    end
  end
end
