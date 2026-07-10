# frozen_string_literal: true

# Applies one consistent order after streams from every provider are merged.
# Cached Real-Debrid streams are always grouped first. Within the RD and
# non-RD groups, streams with a reported seeder count are ordered highest to
# lowest; streams whose provider does not report seeders remain stably ordered
# by the existing language, compatibility, quality, and size preferences.
module StreamOrdering
  QUALITY_ORDER = { "4K" => 0, "1080p" => 1, "720p" => 2, "480p" => 3, "Unknown" => 4 }.freeze

  def self.sort(streams)
    Array(streams)
      .each_with_index
      .sort_by do |stream, original_index|
        seeders = normalized_seeders(stream[:seeders])
        [
          stream[:rd_plus] ? 0 : 1,
          seeders.nil? ? 1 : 0,
          -(seeders || 0),
          stream[:language_score] || 0,
          -(stream[:compatibility_score] || 0),
          QUALITY_ORDER.fetch(stream[:quality], QUALITY_ORDER["Unknown"]),
          -numeric_size(stream[:raw_size]),
          original_index
        ]
      end
      .map(&:first)
  end

  def self.normalized_seeders(value)
    return value.to_i if value.is_a?(Numeric)
    return value.to_i if value.to_s.match?(/\A\d+\z/)

    nil
  end
  private_class_method :normalized_seeders

  def self.numeric_size(value)
    value.is_a?(Numeric) ? value : 0
  end
  private_class_method :numeric_size
end
