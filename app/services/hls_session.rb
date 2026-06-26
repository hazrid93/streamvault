# frozen_string_literal: true

require "fileutils"
require "securerandom"

# Manages HLS transcoding sessions for iOS Safari playback.
#
# Session metadata (session_id, segment_dir, user_id) is persisted in
# the hls_sessions table so any Puma worker or Dokku process can serve
# playlist/segment requests.  The ffmpeg PID is kept in memory in the
# worker that spawned it — only that worker can kill the process, but
# that's fine: the stop endpoint is best-effort, and the 30-minute TTL
# cleans up orphaned sessions.
#
# Thread-safe: the in-memory PID registry uses a mutex.  DB operations
# go through ActiveRecord's own connection pool.
class HlsSession
  SESSION_TTL = 30.minutes
  SHUTDOWN_GRACE_SECONDS = 1

  # In-memory PID registry: session_id => pid (only the worker that
  # spawned ffmpeg can kill it).
  @pids = {}
  # In-memory error registry: session_id => error_message (set by
  # the background monitor thread if ffmpeg exits before producing
  # any segments).  nil means "still starting or succeeded".
  @errors = {}
  @mutex = Mutex.new

  attr_reader :id, :pid, :segment_dir, :user_id

  def self.create(user_id:, input_url:, headers:, start_seconds:, audio_stream:, subtitle_stream:, default_language:, preferred_languages:)
    session_id = SecureRandom.hex(16)
    dir = Rails.root.join("tmp", "hls", session_id).to_s

    # Non-blocking: spawn ffmpeg and return immediately.  A background
    # monitor thread detects failure (ffmpeg exits before producing
    # any segments) and stores the error so the playlist endpoint can
    # return a meaningful failure instead of making the client poll
    # forever.  The client polls the playlist URL until the playlist
    # file appears (200) or the error is set (424).
    pid = TranscodeService.transcode_to_hls(
      input_url,
      segment_dir: dir,
      headers: headers,
      start_seconds: start_seconds,
      audio_stream: audio_stream,
      subtitle_stream: subtitle_stream,
      default_language: default_language,
      preferred_languages: preferred_languages,
      wait_for_first_segment: false
    )

    # Store the PID in memory (only this worker can kill it).
    @mutex.synchronize { @pids[session_id] = pid }

    # Persist session metadata to the DB so any worker can find it.
    record = HlsSessionRecord.create!(
      user_id: user_id,
      session_id: session_id,
      segment_dir: dir,
      pid: pid
    )

    # Background monitor: detect ffmpeg failure so the playlist
    # endpoint can return 424 instead of making the client poll
    # forever.  Runs for up to FIRST_SEGMENT_TIMEOUT_SECONDS; once a
    # segment appears, ffmpeg is healthy and the thread exits.
    monitor_thread = Thread.new do
      begin
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TranscodeService::FIRST_SEGMENT_TIMEOUT_SECONDS
        playlist_path = File.join(dir, "playlist.m3u8")
        loop do
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          if status
            if status.success? && File.exist?(playlist_path) && Dir.glob(File.join(dir, "*.ts")).any?
              break  # ffmpeg finished naturally after producing segments
            end
            # ffmpeg exited without producing segments — record error.
            @mutex.synchronize { @errors[session_id] = "FFmpeg exited (status #{status.exitstatus}) without producing segments." }
            break
          end

          if File.exist?(playlist_path) && Dir.glob(File.join(dir, "*.ts")).any?
            break  # first segment produced — ffmpeg is healthy
          end

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            @mutex.synchronize { @errors[session_id] = "FFmpeg timed out after #{TranscodeService::FIRST_SEGMENT_TIMEOUT_SECONDS}s waiting for first segment." }
            break
          end

          sleep 0.2
        end
      rescue StandardError => e
        @mutex.synchronize { @errors[session_id] = e.message }
      end
    end
    # Don't block shutdown on this thread.
    monitor_thread.abort_on_exception = false

    new(id: session_id, pid: pid, segment_dir: dir, user_id: user_id)
  end

  def self.find(id)
    record = HlsSessionRecord.find_by(session_id: id)
    return nil unless record

    # Check TTL — clean up expired sessions.
    if record.created_at < SESSION_TTL.ago
      stop(id)
      return nil
    end

    pid = @mutex.synchronize { @pids[id] }
    new(id: record.session_id, pid: pid, segment_dir: record.segment_dir, user_id: record.user_id)
  end

  # Returns the error message if ffmpeg failed before producing any
  # segments, or nil if ffmpeg is still starting or succeeded.
  def self.error(id)
    @mutex.synchronize { @errors[id] }
  end

  def self.stop(id)
    record = HlsSessionRecord.find_by(session_id: id)
    return unless record

    pid = @mutex.synchronize { @pids.delete(id) }
    @mutex.synchronize { @errors.delete(id) }
    if pid
      # Only the worker that spawned ffmpeg can kill it.
      killer = HlsSessionKiller.new(pid)
      killer.kill
    end

    FileUtils.rm_rf(record.segment_dir)
    record.destroy!
  rescue ActiveRecord::RecordNotFound
    # already gone
  end

  def self.cleanup_expired
    HlsSessionRecord.where("created_at < ?", SESSION_TTL.ago).find_each do |record|
      stop(record.session_id)
    end
  end

  def playlist_path
    File.join(segment_dir, "playlist.m3u8")
  end

  def segment_path(index)
    File.join(segment_dir, "#{index}.ts")
  end

  private

  def initialize(id:, pid:, segment_dir:, user_id:)
    @id = id
    @pid = pid
    @segment_dir = segment_dir
    @user_id = user_id
  end
end

# Helper class to kill an ffmpeg process group.
class HlsSessionKiller
  def initialize(pid)
    @pid = pid
  end

  def kill
    return if @pid.nil?

    signal_group("CONT")
    signaled = signal_group("TERM")
    return unless signaled

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HlsSession::SHUTDOWN_GRACE_SECONDS
    while group_alive?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end

    signal_group("KILL") if group_alive?
    waitpid_safely
  end

  private

  def signal_group(sig)
    Process.kill(sig, -@pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def group_alive?
    Process.kill(0, -@pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def waitpid_safely
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
  end
end
