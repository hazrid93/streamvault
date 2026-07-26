require "rails_helper"

RSpec.describe StreamPrefetchJob, type: :job do
  around do |example|
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = previous
  end

  let(:user) { create(:user, :with_realdebrid_key, streams_warmed_at: nil) }

  it "atomically claims the user before enqueueing duplicate page triggers" do
    expect(described_class.enqueue_for(user)).to be(true)
    expect(described_class.enqueue_for(user.reload)).to be(false)

    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == described_class }
    expect(jobs.size).to eq(1)
    expect(user.reload.streams_warmed_at).to be_present
  end

  it "does not enqueue while the daily warm claim is fresh" do
    user.update!(streams_warmed_at: 1.hour.ago)

    expect(described_class.enqueue_for(user)).to be(false)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
  end

  it "records completion only after a successful durable warm" do
    prefetcher = instance_double(StreamPrefetcher, warm_all: true)
    allow(StreamPrefetcher).to receive(:new).and_return(prefetcher)
    user.update!(streams_warmed_at: 2.days.ago)

    described_class.perform_now(user.id)

    expect(user.reload.streams_warmed_at).to be > 1.minute.ago
  end

  it "releases the claim when warming cannot run" do
    prefetcher = instance_double(StreamPrefetcher, warm_all: false)
    allow(StreamPrefetcher).to receive(:new).and_return(prefetcher)
    user.update!(streams_warmed_at: Time.current)

    described_class.perform_now(user.id)

    expect(user.reload.streams_warmed_at).to be_nil
  end
end
