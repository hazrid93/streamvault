# frozen_string_literal: true

class Recommendation < ApplicationRecord
  belongs_to :user

  validates :tmdb_id, presence: true
  validates :imdb_id, presence: true

  scope :ordered, -> { order(:position) }

  # Replace all of a user's recommendations in a single transaction.
  # Deletes old rows and inserts new ones with sequential positions.
  # Dedupes by tmdb_id to avoid RecordNotUnique on the (user_id, tmdb_id)
  # unique index, which would otherwise roll back the whole transaction
  # and leave the user with zero recommendations.
  def self.replace_recommendations(user, items)
    rows = items.uniq { |item| item[:tmdb_id] }.each_with_index.map do |item, index|
      {
        user_id: user.id,
        tmdb_id: item[:tmdb_id],
        imdb_id: item[:imdb_id],
        title: item[:title],
        poster_url: item[:poster_url],
        content_type: item[:type],
        year: item[:year]&.to_s,
        position: index,
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    transaction do
      user.recommendations.delete_all
      user.recommendations.insert_all(rows) if rows.any?
    end
  end
end
