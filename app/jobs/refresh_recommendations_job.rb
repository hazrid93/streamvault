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

    Recommendation.replace_recommendations(user, items)
  rescue StandardError => e
    Rails.logger.error("[RefreshRecommendationsJob] error: #{e.message}")
  end

  # Debounce: only enqueue if the lock wasn't already set.  Uses
  # unless_exist: true so the read+write is atomic against Solid Cache
  # (DB-backed) — two concurrent callers can't both see nil and both
  # enqueue, which the old read-then-write pattern allowed.
  def self.enqueue_debounced(user_id)
    lock_key = "recommendations:job:#{user_id}"
    return unless Rails.cache.write(lock_key, true, expires_in: DEBOUNCE_TTL, unless_exist: true)

    perform_later(user_id)
  end
end
