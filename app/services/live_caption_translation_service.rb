# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "securerandom"
require "tempfile"
require "uri"

# Generates English-only timed captions through the private whisper.cpp
# sidecar. Audio and source credentials never leave the Docker host.
class LiveCaptionTranslationService
  WINDOW_SECONDS = 30
  CACHE_TTL = 6.hours.to_i
  CACHE_MAX_ENTRIES = 1_000
  WAIT_TIMEOUT_SECONDS = 150
  MAX_RESPONSE_BYTES = 2.megabytes

  Result = Struct.new(:status, :cues, :window_start, :window_end, :source_language, :message, :retry_after, keyword_init: true) do
    def ok?
      status == :ok
    end
  end
  TranslationFlight = Struct.new(:condition, :done, :result, keyword_init: true)

  @cache = {}
  @language_cache = {}
  @inflight = {}
  @mutex = Mutex.new
  @inference_mutex = Mutex.new

  class << self
    attr_reader :cache, :language_cache, :inflight, :mutex, :inference_mutex

    def enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("LIVE_CAPTIONS_ENABLED", "false")) &&
        ENV["LIVE_CAPTION_WHISPER_URL"].present?
    end

    def reset_cache!
      mutex.synchronize do
        cache.clear
        language_cache.clear
        inflight.clear
      end
    end
  end

  def initialize(endpoint: ENV["LIVE_CAPTION_WHISPER_URL"])
    @endpoint = endpoint.to_s
  end

  def translate(input_url, headers: {}, audio_stream: nil, source_language: nil, start_seconds:, default_language: nil, preferred_languages: [])
    window_start = normalize_start(start_seconds)
    return failure(:invalid, "Invalid caption window") unless window_start
    return failure(:not_configured, "Local live captions are unavailable") unless self.class.enabled? && @endpoint.present?

    window_end = window_start + WINDOW_SECONDS
    key = cache_key(input_url, headers, audio_stream, window_start)
    cached_result = read_cache(key)
    return duplicate_result(cached_result) if cached_result

    flight, owner = acquire_flight(key)
    return wait_for_flight(flight) unless owner

    result = begin
      translate_uncached(
        input_url,
        headers: headers,
        audio_stream: audio_stream,
        window_start: window_start,
        window_end: window_end,
        default_language: default_language,
        preferred_languages: preferred_languages,
        source_language: source_language
      )
    rescue JSON::ParserError
      failure(:invalid_response, "Local Whisper returned an invalid response", retry_after: 5)
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      failure(:timeout, "Local caption generation timed out", retry_after: 5)
    rescue SocketError, SystemCallError
      failure(:unavailable, "Local Whisper is still starting", retry_after: 5)
    rescue StandardError => error
      Rails.logger.warn("[LiveCaption] Translation failed: #{error.class}")
      failure(:failed, "Live caption generation failed", retry_after: 5)
    end

    begin
      write_cache(key, result) if result.ok?
    rescue StandardError => error
      Rails.logger.warn("[LiveCaption] Cache write failed: #{error.class}")
    ensure
      # Every owner path wakes waiters; their timeout remains a final backstop
      # for process termination or an unexpectedly killed Puma thread.
      finish_flight(key, flight, result)
    end
    duplicate_result(result)
  end

  private

  def translate_uncached(input_url, headers:, audio_stream:, window_start:, window_end:, default_language:, preferred_languages:, source_language:)
    inference_lock_acquired = self.class.inference_mutex.try_lock
    return failure(:busy, "Local caption engine is busy", retry_after: 5) unless inference_lock_acquired

    Tempfile.create([ "streamvault-live-caption", ".wav" ]) do |audio_file|
      audio_path = audio_file.path
      audio_file.close
      extraction = TranscodeService.extract_speech_audio(
        input_url,
        output_path: audio_path,
        headers: headers,
        start_seconds: window_start,
        duration_seconds: WINDOW_SECONDS,
        audio_stream: audio_stream,
        default_language: default_language,
        preferred_languages: preferred_languages
      )
      return extraction_failure(extraction) unless extraction.ok?

      extracted_duration = extraction.duration_seconds.to_f
      cue_window_end = extracted_duration.positive? ? [ window_start + extracted_duration, window_end ].min : window_end
      language_key = language_cache_key(input_url, headers, audio_stream)
      known_language = read_language(language_key) || normalize_language_hint(source_language)
      response = request_inference(audio_path, language: known_language || "auto")
      return response unless response.is_a?(Net::HTTPSuccess)

      payload = JSON.parse(response.body)
      return failure(:invalid_response, "Local Whisper did not return an English translation", retry_after: 5) unless payload["task"].to_s == "translate"

      detected_language, confidence = detected_language(payload)
      write_language(language_key, detected_language) if detected_language && confidence >= 0.6
      Result.new(
        status: :ok,
        cues: parse_cues(payload, window_start, cue_window_end),
        window_start: window_start,
        window_end: window_end,
        source_language: detected_language || known_language
      )
    end
  ensure
    self.class.inference_mutex.unlock if inference_lock_acquired
  end

  def request_inference(audio_path, language:)
    uri = URI.parse(@endpoint)
    raise URI::InvalidURIError unless uri.scheme == "http" && uri.host.present?

    boundary = "----StreamVault#{SecureRandom.hex(16)}"
    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    request["Accept"] = "application/json"
    request.body = multipart_body(boundary, audio_path, language)

    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 90) do |http|
      response = http.request(request)
      return failure(:invalid_response, "Local Whisper response was too large") if response.body.to_s.bytesize > MAX_RESPONSE_BYTES

      case response
      when Net::HTTPSuccess
        response
      when Net::HTTPTooManyRequests, Net::HTTPServiceUnavailable
        failure(:busy, "Local caption engine is busy", retry_after: 5)
      else
        failure(:provider_error, "Local caption engine rejected the audio", retry_after: 5)
      end
    end
  end

  def multipart_body(boundary, audio_path, language)
    body = String.new(capacity: File.size(audio_path) + 1_024, encoding: Encoding::BINARY)
    append_field(body, boundary, "response_format", "verbose_json")
    append_field(body, boundary, "translate", "true")
    append_field(body, boundary, "language", language)
    body << "--#{boundary}\r\n"
    body << "Content-Disposition: form-data; name=\"file\"; filename=\"caption.wav\"\r\n"
    body << "Content-Type: audio/wav\r\n\r\n"
    body << File.binread(audio_path)
    body << "\r\n--#{boundary}--\r\n"
    body
  end

  def append_field(body, boundary, name, value)
    body << "--#{boundary}\r\n"
    body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
  end

  def parse_cues(payload, window_start, window_end)
    seen = {}
    Array(payload["segments"]).filter_map do |segment|
      text = segment["text"].to_s.gsub(/\s+/, " ").strip
      next if text.blank?
      next if probable_silence?(segment)

      local_start = Float(segment["start"], exception: false)
      local_end = Float(segment["end"], exception: false)
      next unless local_start&.finite? && local_end&.finite?

      # whisper.cpp timestamps are relative to the uploaded WAV and can
      # overshoot its duration. Rebase by the requested source window and
      # clamp before overlapping windows are merged in the player.
      cue_start = (window_start + local_start).clamp(window_start, window_end)
      cue_end = (window_start + local_end).clamp(window_start, window_end)
      next unless cue_end > cue_start

      cue_end = [ cue_end, cue_start + 12 ].min
      identity = [ (cue_start * 10).round, normalize_identity_text(text) ]
      next if seen[identity]

      seen[identity] = true
      { start: cue_start.round(3), end: cue_end.round(3), text: text }
    end
  end

  def probable_silence?(segment)
    no_speech = Float(segment["no_speech_prob"], exception: false)
    average_log_probability = Float(segment["avg_logprob"], exception: false)
    no_speech && average_log_probability && no_speech > 0.8 && average_log_probability < -1.0
  end

  def detected_language(payload)
    probabilities = payload["language_probabilities"].to_h
    language, confidence = probabilities.max_by { |_code, probability| probability.to_f }
    return [ language.to_s, confidence.to_f ] if language.present?

    value = payload["detected_language"].to_s
    [ value.presence, value.present? ? 1.0 : 0.0 ]
  end

  def normalize_language_hint(value)
    language = value.to_s.strip.downcase
    aliases = {
      "eng" => "en", "fra" => "fr", "fre" => "fr", "spa" => "es",
      "deu" => "de", "ger" => "de", "ita" => "it", "por" => "pt",
      "jpn" => "ja", "kor" => "ko", "zho" => "zh", "chi" => "zh",
      "rus" => "ru", "ara" => "ar", "hin" => "hi", "tur" => "tr",
      "pol" => "pl", "nld" => "nl", "dut" => "nl", "ukr" => "uk"
    }
    normalized = aliases.fetch(language, language)
    normalized if normalized.match?(/\A[a-z]{2}\z/)
  end

  def normalize_start(value)
    number = Float(value, exception: false)
    return unless number&.finite? && number.between?(0, TranscodeService::MAX_VALID_DURATION_SECONDS)

    number.floor
  end

  def normalize_identity_text(text)
    text.downcase.gsub(/[^\p{Alnum}]+/u, " ").strip
  end

  def cache_key(input_url, headers, audio_stream, window_start)
    Digest::SHA256.hexdigest([
      input_url.to_s,
      credential_identity(headers),
      audio_stream.to_s,
      window_start
    ].join("\0"))
  end

  def language_cache_key(input_url, headers, audio_stream)
    Digest::SHA256.hexdigest([
      input_url.to_s,
      credential_identity(headers),
      audio_stream.to_s
    ].join("\0"))
  end

  def credential_identity(headers)
    headers.to_h.transform_keys { |key| key.to_s.downcase }.sort.map do |key, value|
      "#{key}=#{Digest::SHA256.hexdigest(value.to_s)}"
    end.join("&")
  end

  def read_cache(key)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    self.class.mutex.synchronize do
      entry = self.class.cache[key]
      if entry && entry[:expires_at] > now
        entry[:last_access] = now
        entry[:result]
      elsif entry
        self.class.cache.delete(key)
        nil
      end
    end
  end

  def write_cache(key, result)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    self.class.mutex.synchronize do
      self.class.cache[key] = { result: duplicate_result(result), expires_at: now + CACHE_TTL, last_access: now }
      while self.class.cache.length > CACHE_MAX_ENTRIES
        oldest_key, = self.class.cache.min_by { |_cache_key, entry| entry[:last_access] }
        self.class.cache.delete(oldest_key)
      end
    end
  end

  def read_language(key)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    self.class.mutex.synchronize do
      entry = self.class.language_cache[key]
      if entry && entry[:expires_at] > now
        entry[:last_access] = now
        entry[:language]
      elsif entry
        self.class.language_cache.delete(key)
        nil
      end
    end
  end

  def write_language(key, language)
    self.class.mutex.synchronize do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      self.class.language_cache[key] = {
        language: language,
        expires_at: now + CACHE_TTL,
        last_access: now
      }
      while self.class.language_cache.length > CACHE_MAX_ENTRIES
        oldest_key, = self.class.language_cache.min_by { |_cache_key, entry| entry[:last_access] }
        self.class.language_cache.delete(oldest_key)
      end
    end
  end

  def acquire_flight(key)
    self.class.mutex.synchronize do
      if (existing = self.class.inflight[key])
        [ existing, false ]
      else
        flight = TranslationFlight.new(condition: ConditionVariable.new, done: false, result: nil)
        self.class.inflight[key] = flight
        [ flight, true ]
      end
    end
  end

  def wait_for_flight(flight)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WAIT_TIMEOUT_SECONDS
    self.class.mutex.synchronize do
      until flight.done
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return failure(:timeout, "Local caption generation timed out", retry_after: 5) unless remaining.positive?
        flight.condition.wait(self.class.mutex, remaining)
      end
      duplicate_result(flight.result)
    end
  end

  def finish_flight(key, flight, result)
    self.class.mutex.synchronize do
      return if flight.done

      flight.result = duplicate_result(result)
      flight.done = true
      self.class.inflight.delete(key)
      flight.condition.broadcast
    end
  end

  def duplicate_result(result)
    return unless result

    Result.new(
      status: result.status,
      cues: Array(result.cues).map(&:dup),
      window_start: result.window_start,
      window_end: result.window_end,
      source_language: result.source_language,
      message: result.message,
      retry_after: result.retry_after
    )
  end

  def extraction_failure(result)
    case result.status
    when :no_audio then failure(:no_audio, "No audio track is available")
    when :timeout then failure(:timeout, "Audio extraction timed out", retry_after: 5)
    else failure(:extraction_failed, "Could not prepare audio for live captions", retry_after: 5)
    end
  end

  def failure(status, message, retry_after: nil)
    Result.new(status: status, cues: [], message: message, retry_after: retry_after)
  end
end
