FactoryBot.define do
  factory :hls_session_record do
    user
    session_id { SecureRandom.hex(16) }
    segment_dir { Rails.root.join("tmp", "hls", session_id).to_s }
    pid { 12345 }
  end
end
