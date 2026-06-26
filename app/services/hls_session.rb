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
  @mutex = Mutex.new

  attr_reader :id, :pid, :segment_dir, :user_id

  def self.create(user_id:, input_url:, headers:, start_seconds:, audio_stream:, subtitle_stream:, default_language:, preferred_languages:)
    session_id = SecureRandom.hex(16)
    dir = Rails.root.join("tmp", "hls", session_id).to_s

    pid = TranscodeService.transcode_to_hls(
      input_url,
      segment_dir: dir,
      headers: headers,
      start_seconds: start_seconds,
      audio_stream: audio_stream,
      subtitle_stream: subtitle_stream,
      default_language: default_language,
      preferred_languages: preferred_languages
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

  def self.stop(id)
    record = HlsSessionRecord.find_by(session_id: id)
    return unless record

    pid = @mutex.synchronize { @pids.delete(id) }
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
