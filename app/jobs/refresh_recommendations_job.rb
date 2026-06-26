# frozen_string_literal: true

class RefreshRecommendationsJob < ApplicationJob
  queue_as :default

  DEBOUNCE_TTL = 10.minutes

  # Fetches personalised recommendations from TMDB and stores them
  # in the recommendations table (no expiry — they persist until the
  # next refresh replaces them).
  #
  # Triggered after each progress save, but debounced so only one job
  # runs per DEBOUNCE_TTL per user.
  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user
    return if ENV["TMDB_READ_ACCESS_TOKEN"].blank?

    result = RecommendationService.recommendations(user)
    items = result.success? ? result.data : []

    replace_recommendations(user, items)
  rescue StandardError => e
    Rails.logger.error("[RefreshRecommendationsJob] error: #{e.message}")
  end

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

  # Debounce: only enqueue if the job hasn't been enqueued recently.
  def self.enqueue_debounced(user_id)
    lock_key = "recommendations:job:#{user_id}"
    return if Rails.cache.read(lock_key)

    Rails.cache.write(lock_key, true, expires_in: DEBOUNCE_TTL)
    perform_later(user_id)
  end
end
