# frozen_string_literal: true

# Validates content identifier params (imdb_id, type, season, episode)
# against strict formats before they reach services that interpolate
# them into upstream API URL paths.  Prevents path-traversal-like
# attacks against the upstream APIs (Torrentio/Cinemeta/TMDB/Comet)
# where a crafted imdb_id could hit unintended endpoints.
module ContentParamValidation
  IMDB_ID_PATTERN = /\A(tt\d{7,8})\z/.freeze
  VALID_TYPES = %w[movie show].freeze

  # Returns true if +value+ is a valid IMDb ID (e.g. "tt12345678").
  def valid_imdb_id?(value)
    IMDB_ID_PATTERN.match?(value.to_s)
  end

  # Returns true if +value+ is "movie" or "show".
  def valid_content_type?(value)
    VALID_TYPES.include?(value.to_s)
  end

  # Returns true if +value+ is a positive integer (as string or int).
  def valid_episode_number?(value)
    int = value.to_i
    int.to_s == value.to_s && int.positive?
  rescue StandardError
    false
  end

  # Render 400 if +imdb_id+ is invalid; returns true if it rendered.
  def reject_invalid_imdb_id!(imdb_id)
    return false if valid_imdb_id?(imdb_id)
    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, alert: "Invalid content ID." }
      format.json { render json: { error: "Invalid content ID" }, status: :bad_request }
    end
    true
  end

  # Render 400 if +type+ is invalid; returns true if it rendered.
  def reject_invalid_content_type!(type)
    return false if valid_content_type?(type)
    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, alert: "Invalid content type." }
      format.json { render json: { error: "Invalid content type" }, status: :bad_request }
    end
    true
  end
end
