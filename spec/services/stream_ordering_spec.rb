require "rails_helper"

RSpec.describe StreamOrdering do
  it "groups RD streams first and sorts each group by known seeders descending" do
    streams = [
      { title: "non-RD unknown", rd_plus: false, seeders: nil, quality: "4K" },
      { title: "RD low", rd_plus: true, seeders: 4, quality: "1080p" },
      { title: "non-RD high", rd_plus: false, seeders: 80, quality: "720p" },
      { title: "RD unknown", rd_plus: true, seeders: nil, quality: "4K" },
      { title: "RD high", rd_plus: true, seeders: 25, quality: "720p" },
      { title: "non-RD low", rd_plus: false, seeders: 3, quality: "1080p" }
    ]

    expect(described_class.sort(streams).pluck(:title)).to eq([
      "RD high",
      "RD low",
      "RD unknown",
      "non-RD high",
      "non-RD low",
      "non-RD unknown"
    ])
  end

  it "uses existing preferences as tie-breakers and keeps exact ties stable" do
    streams = [
      { title: "first exact tie", rd_plus: true, seeders: nil, quality: "1080p", raw_size: 20 },
      { title: "better language", rd_plus: true, seeders: nil, quality: "4K", language_score: 0 },
      { title: "second exact tie", rd_plus: true, seeders: nil, quality: "1080p", raw_size: 20 },
      { title: "worse language", rd_plus: true, seeders: nil, quality: "4K", language_score: 1 }
    ]

    expect(described_class.sort(streams).pluck(:title)).to eq([
      "better language",
      "first exact tie",
      "second exact tie",
      "worse language"
    ])
  end
end
