# frozen_string_literal: true

class ContentStreamingService
  MAX_STREAM_ATTEMPTS = 50
  RESOLVE_BATCH_SIZE = 10
  RESOLVE_RETRIES = 1

  def initialize(user)
    @user = user
    @providers = StreamProvider.providers(rd_api_key: user.realdebrid_api_key)
  end

  def start_stream(imdb_id, type, season: nil, episode: nil, source_mode: nil,
                   preferred_source: nil, preferred_info_hash: nil, preferred_file_idx: nil)
    preferred_source = normalized_source(preferred_source)
    preferred_info_hash = normalized_info_hash(preferred_info_hash)
    mode = effective_source_mode(source_mode, preferred_source: preferred_source)
    if !@user.has_realdebrid_key? && !LocalTorrentService.enabled?
      return ServiceResult.failure("RealDebrid API key not configured and local torrent playback is unavailable")
    end

    if mode == "local"
      if LocalTorrentService.enabled?
        local_result = start_local_request(
          imdb_id,
          type,
          season: season,
          episode: episode,
          preferred_source: preferred_source,
          preferred_info_hash: preferred_info_hash,
          preferred_file_idx: preferred_file_idx
        )
        return local_result unless automatic_source?(source_mode) && @user.has_realdebrid_key? && local_result.failure?
      elsif !automatic_source?(source_mode) || !@user.has_realdebrid_key?
        return ServiceResult.failure("Local torrent playback is unavailable")
      end

      # A saved local release may temporarily have no reachable peers, use a
      # v2 hash the local engine cannot consume, or local playback may have
      # since been disabled. Automatic mode tries the same identity via RD.
      Rails.logger.warn("[ContentStreamingService] Preferred local source is unavailable for #{imdb_id}; trying RealDebrid")
    end

    return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

    streams_result = fetch_streams(imdb_id, type, season: season, episode: episode)
    rd_result = if streams_result.success? && streams_result.data.any?
      streams = prioritize_stream_identity(streams_result.data, preferred_info_hash, preferred_file_idx)
      start_realdebrid_stream(streams, imdb_id: imdb_id, type: type, season: season, episode: episode)
    else
      ServiceResult.failure(streams_result.failure? ? streams_result.error_message : "No streams available through RealDebrid")
    end

    # Only Automatic mode falls back. RD-only never silently changes source.
    return rd_result unless automatic_source?(source_mode) && LocalTorrentService.enabled? && rd_result.failure?

    Rails.logger.warn("[ContentStreamingService] RealDebrid failed for #{imdb_id}; trying local torrent fallback")
    local_result = fetch_local_streams(imdb_id, type, season: season, episode: episode)
    return rd_result if local_result.failure? || local_result.data.empty?

    streams = prioritize_stream_identity(local_result.data, preferred_info_hash, preferred_file_idx)
    fallback_result = start_local_stream(streams, imdb_id: imdb_id, type: type, season: season, episode: episode)
    fallback_result.success? ? fallback_result : rd_result
  end

  # Resolve a specific stream chosen by the user (via resolve_url).
  # The chosen stream is tried first so a Direct Play MP4 still wins over
  # a fallback MKV, but stale/blocked links are common enough that we
  # retry the current candidate list before failing the request.
  def resolve_single(resolve_url, filename:, imdb_id:, type:, season: nil, episode: nil,
                     source_mode: nil, info_hash: nil, file_idx: nil, title: nil, poster_url: nil)
    if effective_source_mode(source_mode) == "local"
      return LocalTorrentService.new(user: @user).start(
        info_hash: info_hash,
        file_idx: file_idx,
        filename: filename,
        title: title,
        poster_url: poster_url
      )
    end

    return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

    selected_stream = {
      resolve_url: resolve_url,
      filename: filename,
      info_hash: normalized_info_hash(info_hash),
      file_idx: normalized_file_idx(file_idx)
    }
    result = resolve_stream(selected_stream)

    if result
      Rails.logger.info("[ContentStreamingService] User-selected stream resolved for imdb_id=#{imdb_id} filename=#{result[:filename]}")
    else
      Rails.logger.warn("[ContentStreamingService] User-selected stream failed to resolve, falling back for imdb_id=#{imdb_id}")
      result = resolve_fallback_streams(resolve_url, imdb_id, type, season: season, episode: episode)
      if result
        Rails.logger.info("[ContentStreamingService] Fallback stream resolved for imdb_id=#{imdb_id} filename=#{result[:filename]}")
      else
        Rails.logger.warn("[ContentStreamingService] No valid stream found via fallback for imdb_id=#{imdb_id}")
      end
    end

    if result
      stream_result(result, imdb_id: imdb_id, type: type, season: season, episode: episode)
    elsif automatic_source?(source_mode) && LocalTorrentService.enabled? && info_hash.present?
      LocalTorrentService.new(user: @user).start(
        info_hash: info_hash,
        file_idx: file_idx,
        filename: filename,
        title: title,
        poster_url: poster_url
      )
    else
      ServiceResult.failure("Could not resolve the selected stream. It may be blocked or unavailable.")
    end
  end

  private

  def automatic_source?(requested)
    @user.streaming_preference == "automatic" && (requested.blank? || requested == "automatic")
  end

  def effective_source_mode(requested, preferred_source: nil)
    # Forced preferences are policy, not UI defaults: a crafted source_mode
    # parameter must not bypass them. Automatic is the only mode that allows
    # an explicit per-stream Local choice or a saved source preference.
    case @user.streaming_preference
    when "local"
      "local"
    when "realdebrid"
      "realdebrid"
    else
      return "local" if requested == "local"
      return "local" if requested.blank? && preferred_source == "local"

      @user.has_realdebrid_key? ? "realdebrid" : "local"
    end
  end

  def start_local_request(imdb_id, type, season:, episode:, preferred_source:, preferred_info_hash:, preferred_file_idx:)
    return ServiceResult.failure("Local torrent playback is unavailable") unless LocalTorrentService.enabled?

    # A TorrServer URL and lease are ephemeral, but the torrent hash and file
    # index are stable. Resume that identity directly instead of asking a
    # provider to return and re-rank the release again.
    if preferred_source == "local" && preferred_info_hash
      return ServiceResult.failure("Saved torrent identity is unsupported by local playback") unless local_info_hash?(preferred_info_hash)

      result = LocalTorrentService.new(user: @user).start(
        info_hash: preferred_info_hash,
        file_idx: preferred_file_idx,
        title: nil
      )
      return local_content_result(
        result,
        stream: { info_hash: preferred_info_hash, file_idx: preferred_file_idx },
        imdb_id: imdb_id,
        type: type,
        season: season,
        episode: episode
      )
    end

    local_result = fetch_local_streams(imdb_id, type, season: season, episode: episode)
    return local_result if local_result.failure?
    return ServiceResult.failure("No local torrent sources are available for this content") if local_result.data.empty?

    streams = prioritize_stream_identity(local_result.data, preferred_info_hash, preferred_file_idx)
    start_local_stream(streams, imdb_id: imdb_id, type: type, season: season, episode: episode)
  end

  def start_realdebrid_stream(streams, imdb_id:, type:, season:, episode:)
    candidates = stream_candidates(streams)
    result = resolve_first_valid(candidates)
    return stream_result(result, imdb_id: imdb_id, type: type, season: season, episode: episode) if result

    ServiceResult.failure("No instant RealDebrid streams are available; sources may be blocked or unavailable")
  end

  def start_local_stream(streams, imdb_id:, type:, season:, episode:)
    stream = streams.find { |candidate| local_info_hash?(candidate[:info_hash]) }
    return ServiceResult.failure("No local torrent source is available for this title") unless stream

    result = LocalTorrentService.new(user: @user).start(
      info_hash: stream[:info_hash],
      file_idx: stream[:file_idx],
      filename: stream[:filename],
      title: stream[:title] || stream[:name]
    )
    local_content_result(
      result,
      stream: stream,
      imdb_id: imdb_id,
      type: type,
      season: season,
      episode: episode
    )
  end

  def local_content_result(result, stream:, imdb_id:, type:, season:, episode:)
    return result if result.failure?

    ServiceResult.success(result.data.merge(
      stream: stream,
      info_hash: result.data[:info_hash].presence || stream[:info_hash],
      file_idx: result.data[:file_idx].nil? ? stream[:file_idx] : result.data[:file_idx],
      source: "local",
      imdb_id: imdb_id,
      type: type,
      season: season,
      episode: episode
    ))
  end

  BLOCKED_PATTERNS = /downloading|infringing|failed|removed|blocked/i

  # Fetch streams from all configured providers in parallel, merging results.
  # All providers are queried concurrently — a slow or failed Comet doesn't
  # block Torrentio. Results are combined so the best stream wins regardless
  # of which provider found it.
  def fetch_streams(imdb_id, type, season: nil, episode: nil, providers: @providers)
    return ServiceResult.failure("No stream providers available") if providers.empty?

    Rails.logger.info("[ContentStreamingService] fetch_streams: #{providers.length} providers for #{imdb_id} (#{type})")

    threads = providers.map do |provider|
      Thread.new do
        name = provider.class.name
        start = Time.current
        result = provider.streams(
          imdb_id,
          type,
          season: season,
          episode: episode,
          title: nil,
          preferred_languages: @user.preferred_stream_languages,
          default_language: @user.default_stream_language
        )
        elapsed = ((Time.current - start) * 1000).round
        count = result.success? ? result.data.length : 0
        Rails.logger.info("[ContentStreamingService] #{name} returned #{count} streams in #{elapsed}ms")
        result
      end
    end
    results = threads.map(&:value)

    all_streams = []
    results.each do |result|
      all_streams.concat(result.data) if result&.success?
    end

    ServiceResult.success(StreamOrdering.sort(all_streams))
  end

  def fetch_local_streams(imdb_id, type, season:, episode:)
    providers = StreamProvider.providers(rd_api_key: nil)
    fetch_streams(imdb_id, type, season: season, episode: episode, providers: providers)
  end

  def stream_candidates(streams)
    streams.first(MAX_STREAM_ATTEMPTS).select { |s| s[:resolve_url].present? }
  end

  def resolve_stream(stream)
    resolved = verify_resolve_url(stream[:resolve_url])
    return unless resolved

    { **resolved, stream: stream }
  end

  def resolve_fallback_streams(selected_resolve_url, imdb_id, type, season:, episode:)
    streams_result = fetch_streams(imdb_id, type, season: season, episode: episode)
    return if streams_result.failure?

    candidates = stream_candidates(streams_result.data)
      .reject { |stream| stream[:resolve_url] == selected_resolve_url }

    resolve_first_valid(candidates)
  end

  def stream_result(result, imdb_id:, type:, season:, episode:)
    torrent_filename = result[:stream][:filename].presence || result[:filename]

    ServiceResult.success({
      streaming_url: result[:streaming_url],
      filename: torrent_filename,
      stream: result[:stream].merge(filename: torrent_filename),
      source: "realdebrid",
      info_hash: normalized_info_hash(result[:stream][:info_hash]),
      file_idx: normalized_file_idx(result[:stream][:file_idx]),
      imdb_id: imdb_id,
      type: type,
      season: season,
      episode: episode
    })
  end

  def prioritize_stream_identity(streams, preferred_info_hash, preferred_file_idx)
    return streams unless preferred_info_hash

    preferred_index = normalized_file_idx(preferred_file_idx)
    streams.each_with_index.sort_by do |stream, position|
      hash_match = normalized_info_hash(stream[:info_hash]) == preferred_info_hash
      candidate_index = normalized_file_idx(stream[:file_idx])
      exact_file = preferred_index.nil? || candidate_index == preferred_index
      [ hash_match && exact_file ? 0 : 1, hash_match ? 0 : 1, position ]
    end.map(&:first)
  end

  def normalized_source(value)
    source = value.to_s
    source if %w[local realdebrid].include?(source)
  end

  def normalized_info_hash(value)
    hash = value.to_s.strip.downcase
    hash if hash.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
  end

  def local_info_hash?(value)
    value.to_s.match?(LocalTorrentService::INFO_HASH_FORMAT)
  end

  def normalized_file_idx(value)
    index = Integer(value, exception: false)
    index if index && index >= 0
  end

  def resolve_first_valid(candidates)
    candidates.group_by { |stream| stream[:language_score].to_i }.sort_by(&:first).each do |_, language_group|
      language_group.each_slice(RESOLVE_BATCH_SIZE) do |batch|
        winner = resolve_first_valid_batch(batch)
        return winner if winner
      end
    end

    nil
  end

  def resolve_first_valid_batch(candidates)
    completed = Queue.new
    threads = candidates.map do |stream|
      Thread.new(stream) do |candidate|
        resolved = nil
        begin
          resolved = resolve_stream(candidate)
        rescue Exception => error # Resolver isolation: always signal the queue, even for adapter-specific errors.
          raise if error.is_a?(SystemExit) || error.is_a?(Interrupt) || error.is_a?(NoMemoryError)
          Rails.logger.warn("[ContentStreamingService] Failed to resolve stream: #{error.class}: #{error.message}")
        ensure
          completed << resolved
        end
      end
    end

    candidates.length.times do
      winner = completed.pop
      return winner if winner
    end

    nil
  ensure
    threads&.each { |thread| thread.kill if thread.alive? && thread != Thread.current }
  end

  def verify_resolve_url(resolve_url)
    return nil unless allowed_resolve_url?(resolve_url)

    response = with_resolve_retries { resolve_faraday_for(resolve_url).get(resolve_url) }
    return nil unless response

    if [ 301, 302, 303, 307, 308 ].include?(response.status)
      location = response.headers["location"]
      return nil if location.blank?
      return nil if location.match?(BLOCKED_PATTERNS)
      return nil unless http_url?(location)
      # The final streaming URL must be a RealDebrid CDN URL — the
      # resolve URL is an intermediary on the provider (Torrentio/Comet)
      # host, but the Location it redirects to should be the RD download
      # host.  Reject anything else to prevent an untrusted/compromised
      # provider from redirecting the server (which attaches the user's
      # RD API key as a Bearer header) to an attacker-controlled host.
      return nil unless realdebrid_cdn_url?(location)
      filename = location.split("/").last.to_s
      return nil if filename.match?(BLOCKED_PATTERNS)
      { streaming_url: location, filename: filename }
    elsif [ 200, 206 ].include?(response.status)
      # Some Comet playback endpoints return 200 with a tiny trailer/
      # placeholder MP4 instead of 302-redirecting to the actual RD
      # download URL.  Only accept 200 responses from RD CDN hosts —
      # provider hosts that return 200 are almost certainly serving a
      # trailer/placeholder, not the real content.
      return nil unless realdebrid_cdn_url?(resolve_url)
      filename = resolve_url.split("/").last.to_s
      return nil if filename.match?(BLOCKED_PATTERNS)
      { streaming_url: resolve_url, filename: filename }
    else
      nil
    end
  end

  def with_resolve_retries
    attempts = 0

    begin
      attempts += 1
      yield
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed
      retry if attempts <= RESOLVE_RETRIES
      nil
    end
  end

  def allowed_resolve_url?(resolve_url)
    uri = URI.parse(resolve_url.to_s)
    return false unless uri.is_a?(URI::HTTP)

    allowed_resolve_origins.any? do |origin|
      uri.scheme == origin.scheme && uri.host == origin.host && uri.port == origin.port
    end
  rescue URI::InvalidURIError
    false
  end

  def allowed_resolve_origins
    @allowed_resolve_origins ||= StreamProvider.resolve_base_urls.filter_map do |url|
      URI.parse(url)
    rescue URI::InvalidURIError
      nil
    end.uniq { |uri| [ uri.scheme, uri.host, uri.port ] }
  end

  def http_url?(url)
    URI.parse(url.to_s).is_a?(URI::HTTP)
  rescue URI::InvalidURIError
    false
  end

  # The final destination after a resolve-URL redirect must be a
  # RealDebrid CDN host.  Provider hosts (Comet/Torrentio) are
  # intermediaries only — they should never appear as the final
  # streaming_url because the transcode/direct_stream proxies attach
  # the user's RD API key as a Bearer header to whatever host they
  # fetch, and we don't want to send the key to a provider host.
  REALDEBRID_CDN_HOSTS = %w[
    real-debrid.com
    download.real-debrid.com
    streaming.real-debrid.com
  ].freeze

  def realdebrid_cdn_url?(url)
    host = URI.parse(url.to_s).host.to_s.downcase
    REALDEBRID_CDN_HOSTS.any? { |cdn| host == cdn || host.end_with?(".#{cdn}") }
  rescue URI::InvalidURIError
    false
  end

  # Pick the right Faraday client for a resolve URL.  Comet resolve URLs
  # (playback endpoints on the private Comet host) must NOT go through
  # TORRENTIO_PROXY — that proxy is for Torrentio only and blocks traffic
  # to the Comet host.
  def resolve_faraday_for(resolve_url)
    if comet_url?(resolve_url)
      resolve_faraday_direct
    else
      resolve_faraday
    end
  end

  def comet_url?(resolve_url)
    CometService.comet_url.present? && resolve_url.to_s.start_with?(CometService.comet_url)
  end

  def resolve_faraday_direct
    @resolve_faraday_direct ||= Faraday.new do |f|
      f.adapter Faraday.default_adapter
      f.options.timeout = 15
      f.options.open_timeout = 5
    end
  end

  def resolve_faraday
    @resolve_faraday ||= begin
      proxy = ENV["TORRENTIO_PROXY"]
      Faraday.new do |f|
        f.adapter Faraday.default_adapter
        f.options.timeout = 15
        f.options.open_timeout = 5
        f.proxy = proxy if proxy.present?
      end
    end
  end
end
