# frozen_string_literal: true

class TranscodeService
  # Seek-bar thumbnails: one JPEG frame per request with a bounded in-memory
  # cache, single-flight requests, and a small global capture limit.
  # Extended into TranscodeService, so these run as its class methods.
  module Thumbnails
    # Extract one small JPEG frame from the source timeline. Successful frames
    # are cached briefly by source, sanitized credential identity, and timestamp.
    # Concurrent requests for the same key share one capture so dragging cannot
    # fan out identical FFmpeg processes within a Puma worker.
    def extract_thumbnail(input_url, headers: {}, timestamp:)
      numeric_timestamp = Float(timestamp, exception: false)
      unless numeric_timestamp&.finite?
        raise ThumbnailExtractionError, "Invalid thumbnail timestamp"
      end

      second = numeric_timestamp.floor
      raise ThumbnailExtractionError, "Invalid thumbnail timestamp" unless second.between?(0, MAX_VALID_DURATION_SECONDS)

      cache_key = thumbnail_cache_key(input_url, headers, second)
      cached, flight, owner = thumbnail_cache_lookup(cache_key)
      return cached.dup if cached

      unless owner
        result = wait_for_thumbnail_flight(flight)
        return result.dup
      end

      begin
        jpeg = with_thumbnail_capture_slot do
          capture_thumbnail(input_url, headers: headers, timestamp: second)
        end
        store_thumbnail(cache_key, jpeg)
        finish_thumbnail_flight(cache_key, flight, result: jpeg)
        jpeg.dup
      rescue ThumbnailExtractionError => error
        finish_thumbnail_flight(cache_key, flight, error: error)
        raise
      rescue StandardError
        error = ThumbnailExtractionError.new("Thumbnail extraction failed")
        finish_thumbnail_flight(cache_key, flight, error: error)
        raise error
      end
    end

    def thumbnail_cache_key(input_url, headers, timestamp)
      header_identity = ffmpeg_headers(headers).split("\r\n").sort.join("\r\n")
      Digest::SHA256.hexdigest("#{input_url}\0#{header_identity}\0#{timestamp}")
    end
    private :thumbnail_cache_key

    def thumbnail_cache_lookup(cache_key)
      @thumbnail_cache_mutex.synchronize do
        prune_thumbnail_cache
        cached = @thumbnail_cache[cache_key]
        if cached
          cached[:last_accessed_at] = monotonic_now
          return [ cached[:jpeg], nil, false ]
        end

        flight = @thumbnail_inflight[cache_key]
        return [ nil, flight, false ] if flight

        flight = ThumbnailFlight.new(condition: ConditionVariable.new, done: false)
        @thumbnail_inflight[cache_key] = flight
        [ nil, flight, true ]
      end
    end
    private :thumbnail_cache_lookup

    def wait_for_thumbnail_flight(flight)
      @thumbnail_cache_mutex.synchronize do
        flight.condition.wait(@thumbnail_cache_mutex) until flight.done
        raise flight.error.class, flight.error.message if flight.error

        flight.result
      end
    end
    private :wait_for_thumbnail_flight

    def finish_thumbnail_flight(cache_key, flight, result: nil, error: nil)
      @thumbnail_cache_mutex.synchronize do
        flight.result = result
        flight.error = error
        flight.done = true
        @thumbnail_inflight.delete(cache_key) if @thumbnail_inflight[cache_key].equal?(flight)
        flight.condition.broadcast
      end
    end
    private :finish_thumbnail_flight

    def store_thumbnail(cache_key, jpeg)
      @thumbnail_cache_mutex.synchronize do
        prune_thumbnail_cache
        if (replaced = @thumbnail_cache.delete(cache_key))
          @thumbnail_cache_bytes -= replaced[:byte_size]
        end
        while @thumbnail_cache.any? && (
          @thumbnail_cache.size >= THUMBNAIL_CACHE_MAX_SIZE ||
          @thumbnail_cache_bytes + jpeg.bytesize > THUMBNAIL_CACHE_MAX_BYTES
        )
          oldest_key, oldest = @thumbnail_cache.min_by { |_key, entry| entry[:last_accessed_at] }
          @thumbnail_cache.delete(oldest_key)
          @thumbnail_cache_bytes -= oldest[:byte_size]
        end
        now = monotonic_now
        @thumbnail_cache[cache_key] = {
          jpeg: jpeg.freeze,
          stored_at: now,
          last_accessed_at: now,
          byte_size: jpeg.bytesize
        }
        @thumbnail_cache_bytes += jpeg.bytesize
      end
    end
    private :store_thumbnail

    def prune_thumbnail_cache
      cutoff = monotonic_now - THUMBNAIL_CACHE_TTL_SECONDS
      @thumbnail_cache.delete_if do |_key, entry|
        expired = entry[:stored_at] < cutoff
        @thumbnail_cache_bytes -= entry[:byte_size] if expired
        expired
      end
    end
    private :prune_thumbnail_cache

    def with_thumbnail_capture_slot
      acquired = false
      @thumbnail_cache_mutex.synchronize do
        if @thumbnail_active_captures >= THUMBNAIL_MAX_CONCURRENT_CAPTURES
          raise ThumbnailBusyError, "Thumbnail extraction is busy"
        end

        @thumbnail_active_captures += 1
        acquired = true
      end

      yield
    ensure
      if acquired
        @thumbnail_cache_mutex.synchronize do
          @thumbnail_active_captures -= 1
        end
      end
    end
    private :with_thumbnail_capture_slot

    def capture_thumbnail(input_url, headers:, timestamp:)
      header_str = ffmpeg_headers(headers)
      cmd = [ FFMPEG_PATH, "-hide_banner", "-loglevel", "error", "-nostdin" ]
      cmd += [ "-headers", header_str + "\r\n" ] if header_str.present?
      cmd += [
        # Keep probing bounded and accept the nearest keyframe. A seek preview
        # values responsiveness over frame-exact decoding, especially for 4K
        # remote MKV files whose next non-key frame can be expensive to reach.
        "-probesize", "1M",
        "-analyzeduration", "2000000",
        "-ss", timestamp.to_s,
        "-noaccurate_seek",
        "-skip_frame", "nokey",
        "-i", input_url,
        "-map", "0:v:0",
        "-frames:v", "1",
        "-an", "-sn", "-dn",
        "-vf", THUMBNAIL_FILTER,
        "-c:v", "mjpeg",
        "-q:v", "4",
        "-f", "image2pipe",
        "pipe:1"
      ]

      result = capture_command(cmd, timeout_seconds: THUMBNAIL_TIMEOUT_SECONDS)
      raise ThumbnailTimeoutError, "Thumbnail extraction timed out" if result.timed_out
      raise ThumbnailExtractionError, "Thumbnail extraction failed" unless result.status&.success?

      jpeg = result.stdout.to_s.b
      raise ThumbnailExtractionError, "Thumbnail extraction failed" if jpeg.empty? || jpeg.bytesize > THUMBNAIL_MAX_BYTES
      unless jpeg.start_with?("\xFF\xD8\xFF".b) && jpeg.end_with?("\xFF\xD9".b)
        raise ThumbnailExtractionError, "Thumbnail extraction failed"
      end

      jpeg
    end
    private :capture_thumbnail
  end
end
