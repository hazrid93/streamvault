# frozen_string_literal: true

# Determines the next unwatched episode for each series a user is
# following, for the "Up Next" rail on Home.
#
# For every show the user has episode progress for, the service finds the
# highest (season, episode) the user has *finished* (>= 95%) and picks the
# episode immediately after it.  If no episode is finished yet but one is
# in progress, that in-progress episode is returned (resume).  The show's
# episode list is pulled from cinemeta to resolve the next episode's title
# and imdb id.
class UpNextService
  COMPLETED_THRESHOLD = 95
  MAX_SHOWS = 20

  def initialize(rd_api_key: nil)
    @torrentio = TorrentioService.new(rd_api_key: rd_api_key)
  end

  # Returns a ServiceResult wrapping an array of up-next items:
  #   { show_imdb_id, show_title, poster_url, season, episode,
  #     episode_title, episode_imdb_id, resume (bool), progress_percentage }
  def call(user)
    progresses = user.episode_progresses
      .includes(:user)
      .order(last_watched_at: :desc)
      .to_a

    # Group by show, preserving most-recently-watched order.
    shows = {}
    progresses.each do |ep|
      shows[ep.show_imdb_id] ||= []
      shows[ep.show_imdb_id] << ep
    end

    items = shows.first(MAX_SHOWS).filter_map do |show_imdb_id, eps|
      build_item(show_imdb_id, eps)
    end

    ServiceResult.success(items)
  rescue StandardError => e
    Rails.logger.error("[UpNextService] error: #{e.message}")
    ServiceResult.success([])
  end

  private

  def build_item(show_imdb_id, eps)
    # Sort by season then episode to find progression.
    sorted = eps.sort_by { |e| [ e.season_number, e.episode_number ] }
    finished = sorted.select { |e| e.progress_percentage >= COMPLETED_THRESHOLD }
    in_progress = sorted.reject { |e| e.progress_percentage >= COMPLETED_THRESHOLD }

    meta = fetch_show_metadata(show_imdb_id)
    episodes = meta&.dig(:episodes) || []

    next_ep = if finished.any?
      last = finished.last
      find_next_episode(episodes, last.season_number, last.episode_number)
    elsif in_progress.any?
      # Resume the most recently touched in-progress episode.
      resume_ep = eps.max_by(&:last_watched_at)
      episodes.find { |e| e[:season] == resume_ep.season_number && e[:episode] == resume_ep.episode_number } ||
        { season: resume_ep.season_number, episode: resume_ep.episode_number, title: "Episode #{resume_ep.episode_number}", imdb_id: nil }
    end

    return nil unless next_ep

    resume_ep = in_progress.max_by(&:last_watched_at)
    resume = resume_ep.present? && resume_ep.season_number == next_ep[:season] && resume_ep.episode_number == next_ep[:episode]

    {
      show_imdb_id: show_imdb_id,
      show_title: eps.first.show_title,
      poster_url: meta&.dig(:poster_url),
      season: next_ep[:season],
      episode: next_ep[:episode],
      episode_title: next_ep[:title],
      episode_imdb_id: next_ep[:imdb_id],
      resume: resume,
      progress_percentage: resume ? resume_ep.progress_percentage : 0
    }
  end

  # Find the episode that comes right after (season, episode) in the
  # show's episode list, ordered by season then episode number.
  def find_next_episode(episodes, season, episode)
    ordered = episodes.sort_by { |e| [ e[:season], e[:episode] ] }
    idx = ordered.index { |e| e[:season] == season && e[:episode] == episode }
    return nil unless idx
    ordered[idx + 1]
  end

  def fetch_show_metadata(show_imdb_id)
    result = @torrentio.metadata(show_imdb_id, "series")
    result.success? ? result.data : nil
  end
end