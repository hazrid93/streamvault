require "rails_helper"

RSpec.describe CacheWarmerJob, type: :job do
  it "delegates recurring runs to the instrumented warmer" do
    warmer = instance_double(CacheWarmer)
    allow(CacheWarmer).to receive(:new).and_return(warmer)
    allow(warmer).to receive(:warm_all_with_status)

    described_class.perform_now(true)

    expect(warmer).to have_received(:warm_all_with_status).with(periodic: true)
  end

  it "does no upstream work when cache warming is disabled" do
    previous = ENV["DISABLE_CACHE_WARMER"]
    ENV["DISABLE_CACHE_WARMER"] = "true"
    allow(CacheWarmer).to receive(:new)

    described_class.perform_now(true)

    expect(CacheWarmer).not_to have_received(:new)
  ensure
    ENV["DISABLE_CACHE_WARMER"] = previous
  end
end
