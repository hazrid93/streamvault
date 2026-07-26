require "rails_helper"

RSpec.describe ApiCache, type: :model do
  describe ".upsert" do
    it "inserts and atomically updates a cache key" do
      first = described_class.upsert("cinemeta:meta:movie/tt1234567", { title: "First" })
      second = described_class.upsert("cinemeta:meta:movie/tt1234567", { title: "Updated" })

      expect(second.id).to eq(first.id)
      expect(described_class.where(key: first.key).count).to eq(1)
      expect(second.payload).to eq("title" => "Updated")
      expect(second.fetching).to be(false)
      expect(second.fetch_error).to be_nil
      expect(second.cached_at).to be >= first.cached_at
    end

    it "clears a previous refresh error while publishing new data" do
      record = described_class.create!(
        key: "test:error", payload: { old: true }, cached_at: 1.day.ago,
        fetching: true, fetch_error: "timeout"
      )

      described_class.upsert(record.key, { ok: true })

      expect(record.reload).to have_attributes(fetching: false, fetch_error: nil)
    end

    it "rejects a blank key before issuing SQL" do
      expect { described_class.upsert("", { ok: true }) }.to raise_error(ArgumentError, "cache key is required")
    end
  end
end
