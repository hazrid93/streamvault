# frozen_string_literal: true

class ContentController < ApplicationController
  include ContentParamValidation
  before_action :authenticate_user!

  def show
    @imdb_id = params[:imdb_id]
    @type = params[:type]

    return if reject_invalid_imdb_id!(@imdb_id) || reject_invalid_content_type!(@type)

    torrentio = TorrentioService.new(rd_api_key: current_user&.realdebrid_api_key)

    meta_result = torrentio.metadata(@imdb_id, @type)
    @metadata = meta_result.success? ? meta_result.data : nil

    if @type != "show"
      content_title = @metadata&.dig(:title)
      streams_result = fetch_provider_streams(@imdb_id, @type, title: content_title)
      @streams = streams_result.success? ? streams_result.data : []
      @streams_error = streams_result.failure? ? streams_result.error_message : nil
    end

    @library_entry = current_user.library_entries.find_by(imdb_id: @imdb_id)
    @wishlist_entry = current_user.wishlist_entries.find_by(imdb_id: @imdb_id)
    @in_library = @library_entry.present?
    @in_wishlist = @wishlist_entry.present?

    if @type == "show"
      @episode_progress = current_user.episode_progresses.for_show(@imdb_id).index_by { |ep| [ ep.season_number, ep.episode_number ] }
      @selected_season = params[:season]&.to_i || 1
      # Show progress = last watched episode (ordered by watched_at so
      # the result is deterministic — find_by without ORDER BY returns
      # whichever row the DB happens to find first).
      @progress = current_user.watch_history_entries
        .where(show_imdb_id: @imdb_id, content_type: :episode)
        .order(watched_at: :desc).first&.progress_percentage
    else
      # Movie progress
      @progress = current_user.watch_history_entries
        .find_by(imdb_id: @imdb_id, content_type: :movie)
        &.progress_percentage
    end

    # Similar titles via TMDB recommendations.  Wrapped so a TMDB outage
    # or missing token never breaks the detail page — the rail just
    # doesn't render.
    @similar = []
    begin
      tmdb = TmdbService.new
      recs = tmdb.recommendations_for_imdb_id(@imdb_id)
      @similar = recs.success? ? recs.data.first(20) : []
    rescue StandardError => e
      Rails.logger.error("[ContentController] similar titles error: #{e.message}")
      @similar = []
    end
  end

  def status
    imdb_id = params[:imdb_id]
    type = params[:type]
    return if reject_invalid_imdb_id!(imdb_id) || reject_invalid_content_type!(type)

    library_entry = current_user.library_entries.find_by(imdb_id: imdb_id)
    wishlist_entry = current_user.wishlist_entries.find_by(imdb_id: imdb_id)

    render json: {
      in_library: library_entry.present?,
      in_wishlist: wishlist_entry.present?,
      library_entry_id: library_entry&.id,
      wishlist_entry_id: wishlist_entry&.id
    }
  end

  def episode_streams
    @imdb_id = params[:imdb_id]
    @type = params[:type]
    @season = params[:season]&.to_i
    @episode = params[:episode]&.to_i

    return if reject_invalid_imdb_id!(@imdb_id) || reject_invalid_content_type!(@type)

    torrentio = TorrentioService.new(rd_api_key: current_user&.realdebrid_api_key)

    meta = torrentio.metadata(@imdb_id, @type)
    @show_title = meta.success? ? meta.data[:title] : @imdb_id
    @poster_url = meta.success? ? meta.data[:poster_url] : nil
    @episode_title = ""
    @episode_duration_seconds = nil
    if meta.success? && meta.data[:episodes]
      ep = meta.data[:episodes].find { |e| e[:season] == @season && e[:episode] == @episode }
      @episode_title = ep&.dig(:title).to_s
      @episode_duration_seconds = ep&.dig(:runtime_seconds)
    end

    filter_title = "#{@show_title} #{@episode_title}"
    streams_result = fetch_provider_streams(
      @imdb_id,
      "show",
      season: @season,
      episode: @episode,
      title: filter_title
    )
    @streams = streams_result.success? ? streams_result.data : []
    @streams_error = streams_result.failure? ? streams_result.error_message : nil

    render layout: false
  end

  private

  # Fetch streams from all configured providers in parallel, merging results.
  # Per-provider caching (stale-while-revalidate, keyed per-RealDebrid-
  # account) is handled inside each service's #streams — so this method
  # just merges the (possibly cached) provider results.  No controller-
  # level cache is applied here, because the previous shared Rails.cache
  # was keyed without the RD key and could surface one user's resolve URLs
  # (which embed their RD key) to another user.
  def fetch_provider_streams(imdb_id, type, season: nil, episode: nil, title: nil)
    fetch_provider_streams_uncached(imdb_id, type, season: season, episode: episode, title: title)
  end

  def fetch_provider_streams_uncached(imdb_id, type, season: nil, episode: nil, title: nil)
    providers = StreamProvider.providers(rd_api_key: current_user&.realdebrid_api_key)
    all_streams = []

    Rails.logger.info("[ContentController] fetch_provider_streams: #{providers.length} providers for #{imdb_id} (#{type})")

    # Query all providers concurrently — don't let a slow Comet block Torrentio.
    threads = providers.map do |provider|
      Thread.new do
        name = provider.class.name
        start = Time.current
        result = provider.streams(
          imdb_id,
          type,
          season: season,
          episode: episode,
          title: title,
          preferred_languages: current_user.preferred_stream_languages,
          default_language: current_user.default_stream_language
        )
        elapsed = ((Time.current - start) * 1000).round
        count = result.success? ? result.data.length : 0
        Rails.logger.info("[ContentController] #{name} returned #{count} streams in #{elapsed}ms")
        result
      end
    end
    results = threads.map(&:value)

    results.each do |result|
      all_streams.concat(result.data) if result&.success?
    end

    all_streams.empty? ? ServiceResult.failure("No streams available") : ServiceResult.success(all_streams)
  end
end
